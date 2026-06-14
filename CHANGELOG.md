# Changelog

All notable changes to Zenfan are documented here.

---

## [Unreleased]

### Fixed
- **Legacy service migration** — `install.sh` now stops, disables, and removes the pre-rename `zenbook-fan.service` before installing `zenfan.service`, preventing two units from launching the same daemon and fighting over the PWM channel on upgrade. `uninstall.sh` likewise removes the legacy unit so an orphaned copy can no longer keep the daemon running after removal.

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
- **Octal hour parsing** — `date +%H` returns zero-padded values (`08`, `09`) which bash arithmetic treats as invalid octal. Fixed with `$(( 10#$(date +%H) ))` in `zenfan-night-effective` and `zenbook-fan.sh`

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
