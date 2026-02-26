# Hardware Notes

## Detecting hwmon paths

hwmon device indices (`hwmon0`, `hwmon1`, etc.) are assigned at boot and can
change between kernel versions or after hardware changes. Always verify your
paths before first use.

```bash
# List all hwmon devices with their names
for d in /sys/class/hwmon/hwmon*/; do
    echo "$d → $(cat ${d}name 2>/dev/null || echo unknown)"
done
```

Typical output on Zenbook UX31e:
```
/sys/class/hwmon/hwmon0/ → acpitz
/sys/class/hwmon/hwmon1/ → coretemp
/sys/class/hwmon/hwmon2/ → coretemp    ← temp1_input (CPU temp)
/sys/class/hwmon/hwmon3/ → acpitz
/sys/class/hwmon/hwmon4/ → asus_fan    ← pwm1, pwm1_enable (fan)
```

## Changing the paths

If your indices differ, update these files:

**`bin/zenbook-fan.sh`** (lines 32–34):
```bash
PWM="/sys/class/hwmon/hwmonX/pwm1"
ENABLE="/sys/class/hwmon/hwmonX/pwm1_enable"
TEMP="/sys/class/hwmon/hwmonY/temp1_input"
```

**`applet/applet.js`** (lines near top, `SYS` constant):
```javascript
const SYS = {
    temp: "/sys/class/hwmon/hwmonY/temp1_input",
    pwm:  "/sys/class/hwmon/hwmonX/pwm1",
};
```

## Verifying fan control works

```bash
# Enable manual control
echo 1 | sudo tee /sys/class/hwmon/hwmon4/pwm1_enable

# Set fan to 50% (128/255)
echo 128 | sudo tee /sys/class/hwmon/hwmon4/pwm1

# Restore automatic control
echo 2 | sudo tee /sys/class/hwmon/hwmon4/pwm1_enable
```

## PWM range

| Value | ~RPM | Usage |
|-------|------|-------|
| 60 | ~1460 | Minimum (safety floor) |
| 120 | ~2920 | Night acoustic ceiling |
| 180 | ~4376 | Balanced high |
| 255 | ~6200 | Maximum (emergency) |

RPM values are estimates based on linear interpolation from PWM. The actual
RPM curve of the UX31e fan is not perfectly linear at extremes.
