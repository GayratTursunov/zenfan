# Zenfan — Staged Optimization Requirements

Required changes to minimize Zenfan's impact on **LMDE 7** (Cinnamon 6.6.7,
kernel 6.12.90, cjs/mozjs **128**) while preserving behaviour. Derived from
`zenfan_code_review_guide.md`; each requirement carries an ID (R#) traceable to a
finding (C/P/K/G/H).

Every requirement lists **Rationale · Before/After · Files · Impact · Acceptance ·
Risk**. Stages are ordered by impact; implement top-down.

> Status: **Stage 1 (R1, R2) is implemented** alongside this document. Stages 2–5
> are specified here for a later pass.

---

## Stage 1 — Critical correctness *(implemented)*

### R1 — Base-10 guard for the daemon's night-hour arithmetic *(fixes C1)*

**Rationale:** `date +%H` returns zero-padded hours; `08`/`09` are invalid octal,
so `(( HOUR … ))` errors at 08:xx/09:xx — spamming journald every 3 s and leaving
`IN_NIGHT=0` (night limiter silently off). The resolver already guards this.

**Before** — `bin/zenbook-fan.sh:247`
```bash
HOUR=$(date +%H)
IN_NIGHT=0
if (( NIGHT_START > NIGHT_END )); then
    (( HOUR >= NIGHT_START || HOUR < NIGHT_END )) && IN_NIGHT=1
else
    (( HOUR >= NIGHT_START && HOUR < NIGHT_END )) && IN_NIGHT=1
fi
```

**After**
```bash
# Force base-10: date +%H and conf values may be zero-padded (08, 09),
# which bash arithmetic would otherwise reject as invalid octal.
HOUR=$(( 10#$(date +%H) ))
NIGHT_START=$(( 10#$NIGHT_START ))
NIGHT_END=$(( 10#$NIGHT_END ))
IN_NIGHT=0
if (( NIGHT_START > NIGHT_END )); then
    (( HOUR >= NIGHT_START || HOUR < NIGHT_END )) && IN_NIGHT=1
else
    (( HOUR >= NIGHT_START && HOUR < NIGHT_END )) && IN_NIGHT=1
fi
```

**Files:** `bin/zenbook-fan.sh`.
**Impact:** eliminates ~1200 error lines/hour during 08–10:00; night limiter
correct for all windows. **Risk:** none (matches the resolver's proven logic).
**Acceptance:** `faketime '08:30:00' …` over the night block produces no
`value too great for base` and the correct `IN_NIGHT`; daemon journal clean
across the 08/09 window.

### R2 — Remove the applet's recurring timer on teardown *(fixes C2)*

**Rationale:** an un-removed `GLib` source fires against a destroyed applet after
removal/reload → repeating `Gjs-CRITICAL` + leak.

**Before** — `applet/applet.js:514`
```js
startAutoRefresh() {
    GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
        this.updateAll();
        return GLib.SOURCE_CONTINUE;
    });
}
```

**After**
```js
startAutoRefresh() {
    this._refreshId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
        this.updateAll();
        return GLib.SOURCE_CONTINUE;
    });
}

on_applet_removed_from_panel() {
    if (this._refreshId) {
        GLib.source_remove(this._refreshId);
        this._refreshId = 0;
    }
}
```

**Files:** `applet/applet.js`.
**Impact:** no orphaned timer/CPU after removal; clean Looking Glass log.
**Risk:** none. **Acceptance:** add applet → remove it → no recurring
`ZenFanApplet.updateAll` errors in Looking Glass; re-add works.

---

## Stage 2 — Performance & power

### R3 — Eliminate the per-second subprocess storm *(fixes P1)* — biggest win

**Rationale:** profile, night override and schedule already live in files; reading
them in-process removes ~2–3 fork+exec **per second**. Keep `Gio.Subprocess`
only for user-initiated *writes* (profile/night changes).

**Before** — `_readProfile` / `_readNightMode` shell out every tick
```js
async _readProfile() {
    let out = await runAsync([BIN.zenfan, "status"]);   // bash+grep+cut
    return out.replace("Current profile:", "").trim() || "?";
}
async _readNightMode() {
    let mode = await runAsync([BIN.zenfanNight, "status"]);          // bash
    if (mode === "on" || mode === "off") return mode;
    let effective = await runAsync([BIN.zenfanNightEff]);            // bash+date
    return effective || "unknown";
}
```

**After** — pure file reads + the resolver's ~10 lines ported to JS
```js
_readProfile() {
    const text = readSysFile(CONF) || "";
    for (const line of text.split("\n"))
        if (line.startsWith("PROFILE=")) return line.split("=")[1].trim() || "balanced";
    return "balanced";
}

// Mirror of bin/zenfan-night-effective, in-process.
_nightEffective(startHour, endHour) {
    const h = new Date().getHours();
    const inNight = (startHour > endHour)
        ? (h >= startHour || h < endHour)
        : (h >= startHour && h < endHour);
    return inNight ? "auto-on" : "auto-off";
}

_readNightMode(startHour, endHour) {
    const mode = (readSysFile(NIGHT_MODE_FILE) || "auto").trim();   // /tmp file
    if (mode === "on" || mode === "off") return mode;
    return this._nightEffective(startHour, endHour);
}
```
Add `const NIGHT_MODE_FILE = "/tmp/zenfan-night-mode";` near `CONF`, and have
`_readSchedule` (or a small parse) return the numeric `start`/`end` so
`_readNightMode` can compute without spawning. `updateAll`'s `Promise.all`
collapses to synchronous file reads (still fine; reads are instantaneous).

**Files:** `applet/applet.js`. **Impact:** steady-state refresh spawns **0**
processes (down from ~170k–260k execs/day). **Risk:** low — must keep parity with
`zenfan-night-effective` (same `>`/wrap logic; covered by R1's base-10 reasoning,
though JS `getHours()` is already an integer). **Acceptance:** `forkstat -e exec`
shows no `zenfan*`/`bash` spawns while the panel is idle; labels unchanged.

### R4 — Decouple cadence & skip hidden repaints *(fixes P2)*

**Rationale:** temperature wants ~1–2 s; profile/night/schedule change rarely; the
graph only matters when the menu is open.

**After (sketch):**
```js
// Fast tick: temp + panel label + (if menu open) graph.
// Slow path: profile/night/schedule every N ticks or on menu 'open-state-changed'.
_applyToUI(...) {
    if (this.menu.isOpen) this.graphArea.queue_repaint();   // was unconditional
    ...
}
this.menu.connect("open-state-changed", (m, open) => { if (open) this.updateAll(); });
```
Optionally split into `_fastTick()` (1–2 s) and `_slowTick()` (e.g. every 5 s).

**Files:** `applet/applet.js`. **Impact:** fewer Clutter repaints and parses while
idle/closed. **Risk:** low (ensure first paint on menu-open). **Acceptance:**
`pidstat` shows lower idle Cinnamon CPU with the menu closed; graph still live
when open.

### R5 — Replace daemon helper-binary spawns with bash builtins *(fixes P3)*

**Before → After** — `bin/zenbook-fan.sh`
```bash
LOAD=$(awk '{print int($1)}' /proc/loadavg)   →   read -r LOAD _ < /proc/loadavg; LOAD=${LOAD%.*}
HOUR=$(date +%H)                              →   printf -v HOUR '%(%H)T' -1     # then 10#$HOUR
RAW=$(cat "$TEMP")                            →   RAW=$(<"$TEMP")
stat -c %Y "$1"                               →   (keep; or use printf '%(%s)T' with -f checks)
```
`printf '%(...)T'` and `$(<file)` are bash builtins (no fork). Combine with R1's
`10#` guard on `HOUR`.

**Files:** `bin/zenbook-fan.sh`. **Impact:** removes ~3 fork+exec per 3 s loop
(~86k/day). **Risk:** low — verify `LOAD` parsing (`${LOAD%.*}` truncates the
decimal like `int()`). **Acceptance:** `forkstat` shows no `awk`/`date`/`cat`
from the daemon; control behaviour unchanged.

### R6 — Stop rewriting `pwm1_enable` every loop *(fixes P3)*

**Before** — `bin/zenbook-fan.sh:157` writes `echo 1 > "$ENABLE"` every iteration.
**After:** enable once before the loop (already done at line 140) and re-assert
only when a read shows it drifted to `2`:
```bash
[[ "$(<"$ENABLE")" == 1 ]] || echo 1 > "$ENABLE"
```
**Files:** `bin/zenbook-fan.sh`. **Impact:** one fewer sysfs write per tick.
**Risk:** low. **Acceptance:** `pwm1_enable` stays `1`; no extra BIOS-auto flaps.

---

## Stage 3 — Kernel-forward robustness

### R7 — Resolve hwmon paths by name, not by index *(fixes K1)*

**Rationale:** `hwmon2`/`hwmon4` are boot-assigned and can shift across kernel or
driver-load changes; the applet then shows blank data. Resolve by the stable
`name` attribute at startup (the method `docs/HARDWARE.md` already documents).

**Daemon (`bin/zenbook-fan.sh`), at init:**
```bash
hwmon_by_name() {  # $1 = chip name; echoes the hwmonN dir or empty
    local d
    for d in /sys/class/hwmon/hwmon*/; do
        [[ "$(<"$d"name 2>/dev/null)" == "$1" ]] && { echo "$d"; return; }
    done
}
TEMP_DIR=$(hwmon_by_name coretemp); PWM_DIR=$(hwmon_by_name asus)
TEMP="${TEMP_DIR%/}/temp1_input"; PWM="${PWM_DIR%/}/pwm1"; ENABLE="${PWM_DIR%/}/pwm1_enable"
# fall back to the current hardcoded paths if resolution fails, then the existing
# writability check provides the safety net.
```

**Applet (`applet/applet.js`), once in the constructor:**
```js
_resolveHwmon(name) {
    const dir = Gio.File.new_for_path("/sys/class/hwmon");
    const en = dir.enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE, null);
    let info;
    while ((info = en.next_file(null))) {
        const base = "/sys/class/hwmon/" + info.get_name();
        if ((readSysFile(base + "/name") || "") === name) return base;
    }
    return null;
}
// const tempBase = this._resolveHwmon("coretemp") || "/sys/class/hwmon/hwmon2";
// const pwmBase  = this._resolveHwmon("asus")     || "/sys/class/hwmon/hwmon4";
```

**Files:** `applet/applet.js`, `bin/zenbook-fan.sh`, and a note in
`docs/HARDWARE.md`. **Impact:** survives index reshuffles across kernel upgrades.
**Risk:** med — keep the hardcoded values as fallback; verify chip names on the
target (`coretemp`, `asus`). **Acceptance:** force a different index (e.g. unload/
reload a driver, or test on another boot) and confirm Zenfan still finds temp/pwm.

---

## Stage 4 — cjs / GJS modernization (mozjs 128)

### R8 — Replace deprecated `imports.byteArray` with `TextDecoder` *(fixes G1)*

**Before** — `applet/applet.js:73`
```js
return imports.byteArray.toString(raw).trim();
```
**After**
```js
return new TextDecoder().decode(raw).trim();   // raw is a Uint8Array under mozjs128
```
Optionally hoist one decoder: `const _decoder = new TextDecoder();` at module
scope and reuse. **Files:** `applet/applet.js`. **Impact:** removes a deprecation
warning; future-proof for newer cjs. **Risk:** none on mozjs128. **Acceptance:**
no `imports.byteArray` deprecation in Looking Glass; sysfs values still parse.

### R9 — (Optional) Cinnamon Settings API for tunables *(fixes G3)*

**Rationale:** make refresh interval and hwmon chip names user-configurable
without editing source. Add `applet/settings-schema.json` and bind via
`Settings.AppletSettings` (`imports.ui.settings`) → `bindProperty(...)`.
**Files:** new `applet/settings-schema.json`, `applet/applet.js`, installer copies
the schema. **Impact:** maintainability/UX; negligible runtime cost.
**Risk:** low; gated as optional. **Acceptance:** changing the interval in the
applet's settings dialog takes effect without a code edit.

---

## Stage 5 — Hygiene

### R10 — Correct the CHANGELOG octal claim *(fixes H1)*
When R1 lands, fix the 1.3 "Octal hour parsing … in `zenbook-fan.sh`" line (the
guard was only in the resolver until now) and add an entry for the daemon fix.
**Files:** `CHANGELOG.md`. **Risk:** none.

### R11 — Add lint gating *(fixes H3)*
Add `shellcheck bin/*` (and optionally eslint with GJS globals for `applet.js`)
to a pre-commit hook / CI. Would have caught C1 mechanically.
**Files:** repo tooling. **Risk:** none.

---

## Requirement → finding → impact matrix

| R# | Fixes | Stage | Effort | Power/perf impact | Status |
|----|-------|-------|--------|-------------------|--------|
| R1 | C1 | 1 | XS | correctness; stops 3 s log spam | **done** |
| R2 | C2 | 1 | XS | stops leaked timer after teardown | **done** |
| R3 | P1 | 2 | M | **~170k–260k fewer execs/day** | planned |
| R4 | P2 | 2 | M | fewer idle repaints/parses | planned |
| R5 | P3 | 2 | S | ~86k fewer execs/day (daemon) | planned |
| R6 | P3 | 2 | XS | one fewer sysfs write/tick | planned |
| R7 | K1 | 3 | M | resilience across kernel bumps | planned |
| R8 | G1 | 4 | XS | removes deprecation; future-proof | planned |
| R9 | G3 | 4 | M | configurability (optional) | planned |
| R10| H1 | 5 | XS | doc accuracy | planned |
| R11| H3 | 5 | S | prevents regressions | planned |

**Headline:** R3 is the dominant LMDE 7 power/perf win (idle applet drops from
~2–3 process spawns/second to zero). R1/R2 are the correctness must-haves and are
already applied.
