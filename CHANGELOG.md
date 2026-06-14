# Changelog

All notable changes to Zenfan are documented here.

---

## [1.4.0] - 2026-06-14

### Added
- **Applet settings (R9)** — a Cinnamon settings schema (`applet/settings-schema.json`) exposes the **panel refresh interval** (1–10 s) and the **hwmon chip names** (`coretemp`/`asus`) via the applet's Configure dialog, bound with `Settings.AppletSettings`. Changing the interval re-arms the timer live; changing a chip name re-resolves the sysfs paths. The settings provider is released in `on_applet_removed_from_panel()`.
- **Lint gating (R11)** — `tools/lint.sh` checks bash/Python/JSON/JS syntax and runs `shellcheck` (errors gate, warnings advisory); a GitHub Actions workflow (`.github/workflows/ci.yml`) runs it on every push/PR, and an opt-in pre-commit hook (`.githooks/pre-commit`, enabled with `git config core.hooksPath .githooks`) runs it locally.

### Changed
- **Applet: zero-subprocess refresh (R3)** — the panel no longer shells out to `zenfan status`, `zenfan-night status`, or `zenfan-night-effective` every second. Profile, night override, and schedule are read directly from `/etc/zenfan.conf` and `/tmp/zenfan-night-mode`, with the night schedule resolved in-process. Steady-state refresh now spawns **no** processes (was ~2–3 forks/second).
- **Applet: graph repaints only while the menu is open (R4)** — the Cairo temperature graph repaints only when the popup is visible, and a refresh is triggered on menu open.
- **Applet + daemon: hwmon paths resolved by chip name (R7)** — `coretemp`/`asus` are located via `/sys/class/hwmon/*/name` at startup (falling back to the previous fixed indices), surviving hwmon index changes across kernel/driver updates.
- **Daemon: fewer per-loop process spawns (R5/R6)** — load is read with bash builtins instead of `awk`, the hour with `printf '%(%H)T'` instead of `date`, and `pwm1_enable` is only rewritten when it has drifted from `1`.

### Fixed
- **Applet: deprecated `imports.byteArray` (R8)** — replaced with `TextDecoder`, the modern cjs/mozjs128 decode path, removing the deprecation warning.

---

## [1.3.2] - 2026-06-14

### Fixed
- **Daemon octal-hour fault (completes the 1.3 fix)** — `bin/zenbook-fan.sh` used `HOUR=$(date +%H)` inside `(( ))` without the base-10 guard, so at `08:xx`/`09:xx` bash raised `value too great for base` every 3 s and silently left the night limiter off (`IN_NIGHT=0`). Because the expression is a `(( … )) && …` short-circuit, `set -e`/`trap ERR` did not fire, so it logged rather than crashed. Added `$(( 10# … ))` for `HOUR`, `NIGHT_START`, and `NIGHT_END`, matching `zenfan-night-effective`.
- **Applet timer leak** — `applet/applet.js` registered a 1 s `GLib.timeout_add_seconds` without storing the source id and had no teardown hook, so the loop kept firing against a destroyed applet (Gjs-CRITICAL) after removal or a Cinnamon reload. The source id is now stored and removed in `on_applet_removed_from_panel()`.

### Added
- **Code review + optimization docs** — `zenfan_code_review_guide.md` (staged review guide) and `zenfan_new_requirements.md` (staged optimization requirements R1–R11 with before/after code), targeting LMDE 7 / Cinnamon 6.6 / cjs-mozjs128.

---

## [1.3.1] - 2026-06-14

### Fixed
- **Legacy service migration** — `install.sh` now stops, disables, and removes the pre-rename `zenbook-fan.service` before installing `zenfan.service`, preventing two units from launching the same daemon and fighting over the PWM channel on upgrade. `uninstall.sh` likewise removes the legacy unit so an orphaned copy can no longer keep the daemon running after removal.
- **Pipefail-safe unit detection** — the migration check used `systemctl list-unit-files | grep -q`, which is racy under `set -o pipefail` (`grep -q` closes the pipe on match, `systemctl` dies with SIGPIPE, and the pipeline reports failure even when the unit exists). Replaced with `systemctl cat` (no pipe) so the migration fires reliably.

---

## [1.3] - 2026-02-28

### Added
- **Real RPM tachometer** — applet reads `fan1_input` directly from hwmon instead of estimating from PWM
- **BIOS Auto detection** — applet reads `pwm1_enable` every cycle; when daemon is inactive (value=2) it shows `⚙` indicator, disables profile/night controls, and shows `Profile: BIOS Auto`
- **RPM estimation in manual control mode** — when tachometer is unavailable (daemon holds manual control, `fan1_input` returns 0), applet estimates RPM from PWM using linear scale rounded to nearest 100, marked with `~` suffix
- **RPM validity guard** — values above 15000 RPM are shown as `N/A`
- **Last known RPM cache** — applet caches last valid tachometer reading and uses it as fallback
- **Daemon state-aware tooltip** — two distinct tooltip formats: full info when active, simplified BIOS Auto notice when inactive
- **Daemon state-aware fan label** — no percent shown when daemon inactive (BIOS auto mode)
- **Strengthened cleanup trap** — daemon now traps `ERR` in addition to `EXIT INT TERM`; cleanup uses double-write (`echo` + `tee`) to ensure auto mode is always restored on any fault

### Fixed
- **Daemon crash on startup** — `LAST_TEMP=0` caused `RISING=current_temp` on first cycle, falsely triggering rapid-rise protection and pushing PWM far beyond maximum. Fixed by initialising `LAST_TEMP` from the actual sensor reading at startup
- **`set -e` killing daemon on arithmetic** — `((LEARN_OFFSET++))` and `((ERROR_COUNT++))` return exit code 1 when the result is 0, which `set -euo pipefail` treats as failure. Fixed with `|| true`
- **PWM percent calculation** — corrected from `/255` to `/200` then back to `/255` after hardware testing confirmed the ASUS chip accepts and uses the full 0–255 range; `sensors` display of 200=100% was misleading (it uses its own scaling)
- **Octal hour parsing** — `date +%H` returns zero-padded values (`08`, `09`) which bash arithmetic treats as invalid octal. Fixed with `$(( 10#$(date +%H) ))` in `zenfan-night-effective`. *(Correction: the matching guard in `zenbook-fan.sh` was missed at the time — completed in [Unreleased].)*

### Changed
- `_profileItems` stored as array — enables clean `setSensitive()` calls without DOM traversal
- `updatePanelDisplay`, `updateNightMenuState` receive explicit `daemonActive` parameter

---

## [1.2] - 2026-02-26

### Added
- Unified config file `/etc/zenfan.conf` — merged `/etc/zenbook-fan-profile` and `/etc/zenfan-night.conf` into single file
- `zenfan-write-conf` privileged helper — atomic config write via `sudo` with NOPASSWD sudoers rule, replacing unreliable `pkexec tee` approach
- polkit policy `org.zenfan.policy` — documents privilege model
- Fully async applet — all reads use `Promise.all`, zero blocking calls
- GTK dark-themed config GUI (`zenfan-config-gui`) with live schedule preview and polkit-based save
- Cinnamon panel applet with 60-second rolling temperature graph, gradient fill, per-segment colour, 75°C threshold line

### Fixed
- Byte conversion bug in async file reads — `GLib.Bytes` mishandled by `byteArray.toString()` producing stringified arrays
- Absolute binary paths in applet — Cinnamon does not inherit `$PATH`
- GUI privilege escalation — `sudo` strips `$DISPLAY`; fixed by running GUI as user and escalating only the write operation

---

## [1.1] - 2026-02-25

### Added
- Night acoustic mode with configurable schedule
- Auto/manual/forced night mode override via `/tmp/zenfan-night-mode`
- `zenfan-night-effective` schedule evaluator

---

## [1.0] - 2026-02-24

### Added
- Initial release
- Adaptive fan control daemon with three profiles
- Hysteresis, smooth ramp, predictive cooling, adaptive learning offset
- Basic Cinnamon panel applet
