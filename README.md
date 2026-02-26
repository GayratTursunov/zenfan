# Zenfan

Adaptive fan control suite for **ASUS Zenbook UX31e** running **LMDE 7** (Linux Mint Debian Edition) with the **Cinnamon** desktop.

![LMDE 7](https://img.shields.io/badge/LMDE-7-87CEEB?style=flat-square)
![Cinnamon](https://img.shields.io/badge/Cinnamon-6.6-green?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

---

## Features

- **Three fan profiles** — quiet, balanced, performance with adaptive thermal curves
- **Night acoustic mode** — automatic fan limiter during configurable quiet hours
- **Adaptive learning** — offset adjusts over time to your system's thermal behaviour
- **Predictive cooling** — detects rapid temperature rises before throttling occurs
- **Cinnamon panel applet** — live temperature graph, colour-reactive by heat level, one-click profile switching
- **GTK config GUI** — dark-themed night schedule editor with live preview
- **No password prompts** — sudoers NOPASSWD scoped to a single write helper

---

## Repository Structure

```
zenfan/
├── bin/
│   ├── zenbook-fan.sh          # Main daemon (runs as root via systemd)
│   ├── zenfan                  # Fan profile CLI (quiet/balanced/performance/status)
│   ├── zenfan-night            # Night mode override CLI (on/off/auto/status)
│   ├── zenfan-night-effective  # Resolves current auto mode state
│   ├── zenfan-write-conf       # Privileged write helper (called via sudo)
│   └── zenfan-config-gui       # GTK night schedule editor
├── applet/
│   ├── applet.js               # Cinnamon panel applet
│   └── metadata.json           # Applet metadata
├── config/
│   ├── zenfan.conf             # Default unified config
│   ├── org.zenfan.policy       # polkit policy
│   └── zenfan-sudoers          # sudoers drop-in
├── systemd/
│   └── zenfan.service          # systemd service unit
├── docs/
│   ├── HARDWARE.md             # hwmon path detection and hardware notes
│   ├── PROFILES.md             # Fan profile thermal curves explained
│   └── NIGHT_MODE.md           # Night mode logic explained
├── install.sh                  # Automated installer
├── uninstall.sh                # Clean removal script
└── README.md
```

---

## Requirements

| Requirement | Version |
|-------------|---------|
| OS | LMDE 7 (Bookworm base) |
| Desktop | Cinnamon 6.x |
| CJS | 128.0+ |
| Python | 3.11+ |
| Python GTK | `python3-gi`, `gir1.2-gtk-3.0` |
| systemd | any |
| polkit | 126+ |

---

## Quick Install

```bash
git clone https://github.com/GayratTursunov/zenfan.git
cd zenfan
bash install.sh
```

The installer will:
1. Detect hwmon paths and warn if they differ from defaults
2. Install all binaries to `/usr/local/bin/`
3. Create `/etc/zenfan.conf` with defaults (if not already present)
4. Install the sudoers rule (NOPASSWD for `zenfan-write-conf` only)
5. Install the polkit policy and reload polkit
6. Enable and start the systemd service
7. Install the Cinnamon applet

Then add the applet to your panel:
> Right-click panel → Applets → search **Zenfan** → Add to panel

---

## Manual Install

See [docs/INSTALL.md](docs/INSTALL.md) for step-by-step manual installation.

---

## Configuration

All settings live in a single file: `/etc/zenfan.conf`

```ini
PROFILE=balanced      # quiet | balanced | performance
NIGHT_START=22        # quiet period start (0-23)
NIGHT_END=7           # quiet period end (0-23)
```

**Change profile from terminal:**
```bash
zenfan quiet
zenfan balanced
zenfan performance
zenfan status
```

**Change night mode from terminal:**
```bash
zenfan-night on       # force quiet always
zenfan-night off      # disable quiet always
zenfan-night auto     # follow schedule
zenfan-night status   # show current setting
```

**Edit quiet hours:**
```bash
zenfan-config-gui
```

Or use the applet menu → *Configure night hours*.

---

## Hardware Paths

The default hwmon paths are:

| Path | Purpose |
|------|---------|
| `/sys/class/hwmon/hwmon2/temp1_input` | CPU temperature |
| `/sys/class/hwmon/hwmon4/pwm1` | Fan PWM control |
| `/sys/class/hwmon/hwmon4/pwm1_enable` | Manual control enable |

These may differ on your system. See [docs/HARDWARE.md](docs/HARDWARE.md) for detection instructions.

---

## Privilege Model

| Operation | Method | Requires |
|-----------|--------|----------|
| Read temperature / PWM | sysfs file read | None |
| Read config | File read | None |
| Write config (profile/schedule) | `sudo zenfan-write-conf` | NOPASSWD (sudoers.d) |
| Night mode override | Write to `/tmp` | None |
| Fan PWM control | systemd daemon runs as root | systemd |

The sudoers rule grants **only** the `sudo` group passwordless access to `/usr/local/bin/zenfan-write-conf`, which validates its input and performs an atomic write to `/etc/zenfan.conf`. No other binary has elevated privileges.

---

## Applet

The Cinnamon panel applet shows:
- Live temperature with colour coding: ❄ cool → 🌡 warm → 🔥 hot
- 🌙 indicator when night acoustic mode is active
- 60-second rolling temperature graph with gradient fill and per-segment colour
- Fan speed (estimated from PWM)
- Profile and night mode status
- One-click profile switching and night mode control

---

## Uninstall

```bash
bash uninstall.sh
```

Optionally preserves `/etc/zenfan.conf`.

---

## License

MIT — see [LICENSE](LICENSE)
