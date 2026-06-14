# Zenfan — Staged Code Review Guide

A repeatable, staged review process for the Zenfan adaptive fan-control suite on
**LMDE 7** (Cinnamon 6.6.7, kernel 6.12.90, cjs/mozjs **128**, X11/Muffin).

Each stage states **what to check**, **how to check it** (tools/commands), and
the **findings already mapped** from the current tree (with `file:line` and a
severity). Severities: **High** (correctness/leak), **Med** (perf/compat),
**Low/Info** (hygiene). Run the stages top-to-bottom; later stages assume the
earlier ones passed.

> Companion document: `zenfan_new_requirements.md` turns these findings into
> staged, code-level optimization requirements (R1–R11).

---

## Stage 0 — Orientation (architecture & data flow)

**Goal:** understand the moving parts before judging any line.

| Component | File | Runs as | Role |
|-----------|------|---------|------|
| Daemon | `bin/zenbook-fan.sh` | root (systemd `zenfan.service`) | reads temp/load, writes `pwm1`; the only writer of fan speed |
| Profile CLI | `bin/zenfan` | user | reads/sets `PROFILE=` in `/etc/zenfan.conf` (writes via `sudo zenfan-write-conf`) |
| Night CLI | `bin/zenfan-night` | user | writes `/tmp/zenfan-night-mode` (on/off/auto) |
| Night resolver | `bin/zenfan-night-effective` | user | maps schedule → `auto-on`/`auto-off` |
| Write helper | `bin/zenfan-write-conf` | root via `sudo` (NOPASSWD) | validated, atomic write of `/etc/zenfan.conf` |
| Config GUI | `bin/zenfan-config-gui` | user (GTK3) | edits night hours; saves via `sudo zenfan-write-conf` |
| Applet | `applet/applet.js` | Cinnamon (cjs) | panel UI: temp graph, profile/night controls |

**Data flow:** daemon ⇄ sysfs (`hwmon`) and `/etc/zenfan.conf` (+ `/tmp` state);
applet reads sysfs + conf + `/tmp/zenfan-night-mode`, and shells out to the CLIs
for status/writes. Single source of truth for settings: `/etc/zenfan.conf`.

**How to orient:**
```bash
systemctl cat zenfan.service          # confirm unit + ExecStart
git ls-files | sort                   # inventory
sed -n '30,40p' applet/applet.js      # SYS/CONF constants
sed -n '31,40p' bin/zenbook-fan.sh    # hardware interfaces
```

**Checklist:** ✅ privilege boundaries clear · ✅ one config file · ✅ daemon is
the sole pwm writer · ✅ applet is read-mostly.

---

## Stage 1 — Correctness

**What to check:** arithmetic edge cases, error handling, resource teardown,
and behavioural parity between the daemon's night logic and the resolver.

**How:**
```bash
bash -n bin/*.sh bin/zenfan bin/zenfan-night*      # parse-only
shellcheck bin/zenbook-fan.sh bin/zenfan*          # static analysis
# Cinnamon JS errors at runtime:  Looking Glass (Alt+F2 → lg) → "Log" tab
journalctl -u zenfan -n 200 --no-pager | grep -i 'base\|error'
```

**Findings:**

- **C1 · High · `bin/zenbook-fan.sh:247`** — octal-hour fault.
  `HOUR=$(date +%H)` is consumed by `(( ))` at lines 250/252 with **no base-10
  guard**. At `08:xx`/`09:xx`, `date +%H` yields `08`/`09`, which bash rejects in
  arithmetic (`value too great for base (error token is "08")`). Because the
  expression is in a `(( … )) && IN_NIGHT=1` short-circuit, `set -e`/`trap ERR`
  do **not** fire (verified) — so the daemon survives, but it (a) logs the error
  every 3 s for two hours a day and (b) leaves `IN_NIGHT=0`, silently disabling
  the night limiter for any window overlapping 08:00–09:59.
  `bin/zenfan-night-effective:14-16` already applies `10#`; the daemon does not.
  **Doc drift:** CHANGELOG 1.3 claims this was fixed "in `zenbook-fan.sh`". → **R1**

- **C2 · High · `applet/applet.js:514`** — leaked GLib source.
  `startAutoRefresh()` registers a 1 s `GLib.timeout_add_seconds` returning
  `SOURCE_CONTINUE`, but never stores the id and the applet defines no
  `on_applet_removed_from_panel()`. When the applet is removed or Cinnamon
  reloads, the callback keeps firing against a destroyed instance → repeating
  `Gjs-CRITICAL` and a leaked timer. → **R2**

- **C3 · Info** — error swallowing. `readSysFile` and the `_read*` helpers use
  empty `catch {}` / `|| return null`. Acceptable for a panel applet (never let a
  transient read crash the UI), but reviewers should confirm each fallback path
  produces a sensible UI state (it does: `--`, `N/A`, `?`).

**Checklist:** ✅ no zero-padded values reach `(( ))` without `10#` · ✅ every
recurring GLib/Mainloop source is removed on teardown · ✅ daemon/resolver agree
on the same night window for all 24 hours.

---

## Stage 2 — Performance & power (headline concern on a 2011 ultrabook)

**What to check:** how much work happens **per tick**, especially process spawns
and repaints, and whether work happens when nothing is visible.

**How:**
```bash
# Count fork/exec caused by the applet (watch while the panel is idle):
sudo forkstat -e exec | grep -E 'zenfan|bash|grep|cut|date'
pidstat -p $(pgrep -f cinnamon) 1 10      # CPU of the Cinnamon process
# Daemon spawn rate:
sudo forkstat -e exec | grep -E 'awk|date|stat|cat'
```

**Findings:**

- **P1 · High · `applet/applet.js:365` (`updateAll`, 1 s tick)** — subprocess
  storm. Every second the applet spawns:
  `zenfan status` → `bash`+`grep`+`cut`; `zenfan-night status` → `bash`; and
  (when night = auto) `zenfan-night-effective` → `bash`+`date`. That is ~2–3
  process spawns **every second, forever** (~170k–260k execs/day) for data that
  already sits in `/etc/zenfan.conf` and `/tmp/zenfan-night-mode`.
  `_readSchedule` (line 332) already proves the pattern: read the file directly.
  → **R3**

- **P2 · Med · `applet/applet.js`** — coupled cadence & hidden repaint.
  Panel temperature wants ~1–2 s; profile/night/schedule change only on user
  action. Everything is recomputed at 1 s. Also `graphArea.queue_repaint()`
  (line 441) is requested every tick regardless of whether the menu is open. → **R4**

- **P3 · Low · `bin/zenbook-fan.sh` (3 s loop)** — micro-spawns:
  `awk` on `/proc/loadavg` (178), `date +%H` (247), `stat` (99 via `get_mtime`),
  `cat` (163). Each is a fork+exec every 3 s; all replaceable with bash builtins
  (`read`, `printf '%(%H)T' -1`, `$(<file)`). Also `echo 1 > "$ENABLE"` (157)
  rewrites the enable flag every loop. The daemon is the system's "engine" so
  this is lower priority than P1, but it is free power savings. → **R5/R6**

**Checklist:** ✅ steady-state applet refresh spawns **zero** processes ·
✅ expensive redraws gated on visibility · ✅ daemon loop uses builtins, not
helper binaries.

---

## Stage 3 — Platform compatibility (kernel 6.12 → future, cjs/mozjs 128, Cinnamon 6.6)

> Note on "kernel 7.1": as of mid-2026 no 7.x kernel exists; 6.12 is the current
> LTS. Treat the request as **forward-compatibility hygiene** — do not depend on
> volatile interfaces — rather than coding to a specific 7.x API.

**What to check:** assumptions that break across a kernel/driver/cjs bump.

**How:**
```bash
for d in /sys/class/hwmon/hwmon*/; do printf '%s -> %s\n' "$d" "$(cat "$d"name 2>/dev/null)"; done
cjs --version 2>/dev/null; dpkg -l | grep -E 'cjs|mozjs'   # confirm mozjs128
# Deprecation warnings surface in Looking Glass / ~/.xsession-errors
```

**Findings:**

- **K1 · Med · `applet/applet.js:30` + `bin/zenbook-fan.sh:32`** — hardcoded
  `hwmon2`/`hwmon4`. hwmon indices are assigned at boot and can shift across
  kernel upgrades or driver load-order changes. The daemon at least fails loudly
  (it checks writability and exits), but the applet silently shows blank/garbage.
  Stable approach: resolve indices at startup by reading
  `/sys/class/hwmon/*/name` (`coretemp` → temp, `asus`/`asus-nb-wmi` → pwm) — the
  exact method already documented manually in `docs/HARDWARE.md`. The underlying
  `pwm1`/`pwm1_enable`/`temp1_input` sysfs ABI is stable; **no deprecated kernel
  interface is in use.** → **R7**

- **G1 · Med · `applet/applet.js:73`** — deprecated `imports.byteArray`.
  Under mozjs128, `imports.byteArray.toString()` is deprecated; `GLib.file_get_contents`
  returns a `Uint8Array`, so use `new TextDecoder().decode(raw)`. → **R8**

- **G2 · Info** — already modern & compliant: ES6 `class` (not `Lang.Class`),
  `Gio._promisify`, `async`/`await`, manual `cr.$dispose()` on the Cairo context
  (line 284), absolute binary paths (Cinnamon doesn't inherit `$PATH`). Keep these.

- **G3 · Low (optional)** — no Cinnamon **Settings API**. Refresh interval and
  hwmon paths are source constants. A `settings-schema.json` + `AppletSettings`
  would make them user-configurable without editing `applet.js`. → **R9**

- **G4 · Low** — Linux Mint cjs guide micro-perf: prefer **named callbacks** over
  inline closures in signal handlers, and minimise signal listeners. Marginal
  here (few handlers); note for future growth.

**Checklist:** ✅ no hardcoded hwmon index in shipped code · ✅ no deprecated
cjs/GJS call on a hot path · ✅ deprecation warnings absent from Looking Glass.

---

## Stage 4 — Security & privilege

**What to check:** the escalation surface and the integrity of writes.

**How:**
```bash
sudo cat /etc/sudoers.d/zenfan          # scope of NOPASSWD
pkaction --action-id org.zenfan.write-conf --verbose
sed -n '1,30p' bin/zenfan-write-conf    # validation + atomicity
ls -l /tmp/zenfan-night-mode            # intentional world-writable override
```

**Findings:**

- **S1 · Info** — model is sound and minimal:
  `zenfan-write-conf` reads stdin to a `mktemp` file, rejects content without a
  `KEY=value` line, then `mv` (atomic) + `chmod 644`. NOPASSWD is scoped to that
  single helper, not a shell. The night override lives in `/tmp` by design
  (any desktop user may toggle night mode; the daemon clamps fan speed, so the
  blast radius is "fan a bit quieter/louder", bounded by `NIGHT_OVERRIDE_TEMP`).
  **Reviewer nits to keep an eye on:** (a) the helper's sanity regex
  `^[A-Z_]*=` also matches a bare `=` line — harmless but could be tightened to
  `^[A-Z_]\+=`; (b) `/tmp` is shared, so do not migrate any *trusted* state there.

**Checklist:** ✅ escalation limited to one validated helper · ✅ config writes
atomic · ✅ no privileged data in world-writable paths.

---

## Stage 5 — Maintainability & docs

**What to check:** code/doc drift, changelog accuracy, lint gating.

**How:**
```bash
shellcheck bin/*                         # add to CI/pre-commit
# (optional) eslint applet.js with a GJS globals config
grep -n 'zenbook-fan.sh' CHANGELOG.md    # verify claims against the file
```

**Findings:**

- **H1 · Low** — CHANGELOG 1.3 states the octal-hour fix was applied to
  `zenbook-fan.sh`; it was not (see C1). Correct the entry when R1 lands. → **R10**
- **H2 · Low** — `docs/HARDWARE.md` documents hwmon detection by name but the
  code hardcodes indices (see K1) — close the doc/code gap when R7 lands.
- **H3 · Low** — no automated lint. A `shellcheck` pass (and optionally eslint
  for the applet) would have surfaced C1/C3 mechanically. → **R11**

**Checklist:** ✅ every CHANGELOG claim traceable to code · ✅ docs match shipped
paths · ✅ lint runs in CI / pre-commit.

---

## Severity rollup

| ID | Stage | Severity | One-liner | Requirement |
|----|-------|----------|-----------|-------------|
| C1 | 1 | High | daemon octal-hour arithmetic fault | R1 |
| C2 | 1 | High | applet 1 s timer never removed | R2 |
| P1 | 2 | High | ~2–3 subprocess spawns/sec in applet | R3 |
| P2 | 2 | Med | one cadence for all reads; hidden repaint | R4 |
| P3 | 2 | Low | daemon micro-spawns + redundant enable write | R5/R6 |
| K1 | 3 | Med | hardcoded hwmon indices | R7 |
| G1 | 3 | Med | deprecated `imports.byteArray` | R8 |
| G3 | 3 | Low | no Settings API | R9 |
| S1 | 4 | Info | privilege model sound (minor nits) | — |
| H1–H3 | 5 | Low | changelog/doc drift, no lint | R10/R11 |

**Suggested fix order:** C1, C2 (correctness) → P1 (the big power win) → K1, G1
→ P2/P3 → G3, H1–H3.
