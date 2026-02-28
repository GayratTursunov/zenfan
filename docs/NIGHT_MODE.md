# Night Acoustic Mode

Night mode limits the fan to a maximum PWM of 150 (~58% of 255) during
configured quiet hours, reducing acoustic noise while sleeping.

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
Handles wrap-around midnight correctly.

## Safety override

If temperature exceeds `NIGHT_OVERRIDE_TEMP` (default 72 °C), the quiet
ceiling is lifted and the fan runs at whatever speed thermal management
requires.

## Changing quiet hours

```bash
zenfan-config-gui        # graphical editor
# or edit directly:
sudo nano /etc/zenfan.conf
```
