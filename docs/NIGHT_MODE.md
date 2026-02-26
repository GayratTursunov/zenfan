# Night Acoustic Mode

Night mode limits the fan to a maximum PWM of 120 (~2920 RPM estimated)
during configured quiet hours, reducing acoustic noise while sleeping.

## States

| State | Meaning |
|-------|---------|
| `on` | Quiet mode forced on regardless of time |
| `off` | Quiet mode disabled regardless of time |
| `auto` | Follow the schedule in `/etc/zenfan.conf` |
| `auto-on` | Auto mode, currently within quiet hours |
| `auto-off` | Auto mode, currently outside quiet hours |

## Schedule

Configured via `NIGHT_START` and `NIGHT_END` in `/etc/zenfan.conf`.

The schedule handles wrap-around midnight correctly:
- `NIGHT_START=22, NIGHT_END=7` → quiet from 22:00 to 07:00 (crosses midnight)
- `NIGHT_START=1,  NIGHT_END=6` → quiet from 01:00 to 06:00 (same night)

## Safety override

If temperature exceeds `NIGHT_OVERRIDE_TEMP` (default 72 °C), the quiet
ceiling is lifted and the fan runs at whatever speed thermal management
requires. This prevents thermal throttling during night workloads.

## State persistence

The manual override state (`on` / `off`) is stored in `/tmp/zenfan-night-mode`.
This file is cleared on reboot, returning to `auto` mode.

## Changing quiet hours

**Via GUI:**
```bash
zenfan-config-gui
```
Or use the applet menu → *Configure night hours*.

**Via config file directly:**
```bash
sudo nano /etc/zenfan.conf
# Edit NIGHT_START and NIGHT_END
```

The daemon and `zenfan-night-effective` use mtime caching — changes are
picked up within one daemon cycle (3 seconds) without a restart.
