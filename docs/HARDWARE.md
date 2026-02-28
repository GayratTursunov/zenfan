# Hardware Notes

## Detecting hwmon paths

hwmon device indices (`hwmon0`, `hwmon1`, etc.) are assigned at boot and can
change between kernel versions or after hardware changes. Always verify your
paths before first use.

```bash
# List all hwmon devices with their names
for d in /sys/class/hwmon/hwmon*/; do
    echo "$d → $(cat ${d}name 2>/dev/null || echo unknown)"
    ls $d
done
```

Typical output on Zenbook UX31e:
```
/sys/class/hwmon/hwmon2/ → coretemp    ← temp1_input (CPU temp)
/sys/class/hwmon/hwmon4/ → asus        ← pwm1, pwm1_enable, fan1_input (fan)
```

## sysfs interface

| File | Values | Purpose |
|------|--------|---------|
| `hwmon4/pwm1` | 0–255 | Fan PWM (0=off, 255=full speed) |
| `hwmon4/pwm1_enable` | 1=manual, 2=auto | Control mode |
| `hwmon4/fan1_input` | RPM | Live tachometer (only in auto mode) |
| `hwmon2/temp1_input` | millidegrees | CPU temperature |

**Note on `fan1_input`:** The tachometer only reports RPM when `pwm1_enable=2`
(BIOS/auto mode). When the Zenfan daemon sets `pwm1_enable=1` (manual control),
`fan1_input` returns 0 or empty. The applet handles this by estimating RPM from
PWM (rounded to nearest 100, marked with `~`).

**Note on PWM range:** The ASUS chip accepts 0–255 via sysfs. The `sensors`
tool displays this as 0–200=100% using its own scaling, but the hardware
uses the full 0–255 range. PWM 255 = maximum fan speed.

## Changing the paths

If your indices differ, update these files:

**`bin/zenbook-fan.sh`** (near top):
```bash
PWM="/sys/class/hwmon/hwmonX/pwm1"
ENABLE="/sys/class/hwmon/hwmonX/pwm1_enable"
TEMP="/sys/class/hwmon/hwmonY/temp1_input"
```

**`applet/applet.js`** (`SYS` constant near top):
```javascript
const SYS = {
    temp:      "/sys/class/hwmon/hwmonY/temp1_input",
    pwm:       "/sys/class/hwmon/hwmonX/pwm1",
    pwmEnable: "/sys/class/hwmon/hwmonX/pwm1_enable",
    rpm:       "/sys/class/hwmon/hwmonX/fan1_input",
};
```

## Verifying fan control works

```bash
# Enable manual control
echo 1 | sudo tee /sys/class/hwmon/hwmon4/pwm1_enable

# Set fan to ~50% (128/255)
echo 128 | sudo tee /sys/class/hwmon/hwmon4/pwm1

# Set fan to full speed
echo 255 | sudo tee /sys/class/hwmon/hwmon4/pwm1

# Restore automatic control
echo 2 | sudo tee /sys/class/hwmon/hwmon4/pwm1_enable
```
