# Fan Profiles

The daemon uses temperature zone mapping with hysteresis to select a PWM
target. Three built-in profiles cover different use cases.

## Profile comparison

| Zone boundary | quiet | balanced | performance |
|---------------|-------|----------|-------------|
| LOW  | 55 °C | 50 °C | 45 °C |
| MID  | 65 °C | 60 °C | 55 °C |
| HIGH | 75 °C | 70 °C | 65 °C |
| MAX  | 85 °C | 80 °C | 75 °C |

| PWM step | quiet | balanced | performance |
|----------|-------|----------|-------------|
| P1 (below LOW)  | 30  | 70  | 100 |
| P2 (LOW→MID)    | 60  | 100 | 140 |
| P3 (MID→HIGH)   | 100 | 140 | 180 |
| P4 (HIGH→MAX)   | 170 | 180 | 210 |
| P5 (above MAX)  | 210 | 220 | 255 |

## Hysteresis

A 3 °C hysteresis band prevents the fan from oscillating when temperature
hovers near a zone boundary. The zone only changes when temperature crosses
`boundary ± 3 °C`.

## Smooth ramp

PWM changes by at most 8 units per cycle (every 3 seconds). This prevents
abrupt fan speed changes that would be acoustically jarring.

## Adaptive learning

The daemon tracks a `LEARN_OFFSET` that shifts zone boundaries based on
observed thermal behaviour:

- Temperature stays above 75 °C → offset increases (fan spins up earlier)
- Temperature stays below 50 °C → offset decreases (fan spins up later)
- Offset clamped to `[-5, +15]`

The offset persists in `/tmp/zenfan-state` across daemon restarts (but not
reboots).

## Emergency overrides

These override all profile logic:

| Condition | Action |
|-----------|--------|
| Temp ≥ 85 °C | PWM = 255 (full speed) |
| Temp ≥ 78 °C and rising | PWM = 220 (strong cooling) |
| Rapid rise ≥ 3 °C/cycle | TARGET += 40 |
| Load ≥ 3 (1-min avg) | TARGET += 25 |
