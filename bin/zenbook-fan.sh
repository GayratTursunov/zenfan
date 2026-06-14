#!/bin/bash
#
# Zenfan — adaptive thermal control for ASUS Zenbook UX31e
# Version: 1.3
# --------------------------------------------------------
# This daemon continuously monitors CPU temperature and system load,
# then dynamically adjusts fan PWM for:
#
#   • acoustic comfort
#   • thermal stability
#   • throttling prevention
#   • adaptive learning behavior
#   • night-time quiet operation
#
# The controller uses:
#   - temperature zones
#   - hysteresis stabilization
#   - smoothing ramp
#   - predictive cooling
#   - environment learning offset
#   - optional night acoustic limiter
#
# Runs as root via systemd. Logs to journald.
#
# Optimizations: Strict error handling, logging, mtime-based caching,
# fallbacks, cleanup trap, efficient I/O.

set -euo pipefail  # Strict mode: exit on error, unset vars, pipe failures
umask 077          # Secure temp files

### --- Hardware interfaces ---
PWM="/sys/class/hwmon/hwmon4/pwm1"            # Fan control output
ENABLE="/sys/class/hwmon/hwmon4/pwm1_enable"  # Enable manual control
TEMP="/sys/class/hwmon/hwmon2/temp1_input"    # CPU temperature (millidegrees C)

### --- State & configuration files ---
CONF="/etc/zenfan.conf"                # Unified config: profile + night schedule
STATE_FILE="/tmp/zenfan-state"         # Runtime learning persistence
NIGHT_MODE_FILE="/tmp/zenfan-night-mode"  # Manual override (on/off)

### --- Thermal protection thresholds ---
THROTTLE_TEMP=85       # Emergency full cooling
PREEMPT_TEMP=78        # Proactive cooling zone
RAPID_RISE=3           # °C jump considered dangerous
FORCE_COOL_PWM=220     # Strong cooling step

### --- Night acoustic limiter defaults ---
# Quiet mode reduces fan noise during configured hours.
# Automatically disabled when temperature becomes unsafe.
NIGHT_START=22              # Quiet period start hour
NIGHT_END=7                 # Quiet period end hour
NIGHT_MAX_PWM=150           # Maximum fan power allowed at night
NIGHT_OVERRIDE_TEMP=72      # Disable quiet mode above this temp

### --- Control stability parameters ---
HYST=3          # Hysteresis band prevents oscillation
STEP=8          # Max PWM change per cycle (smooth ramp)
MAX_OFFSET=15   # Learning sensitivity limit

### --- Runtime variables ---
LAST_PWM=100
LAST_TEMP=$(( $(cat /sys/class/hwmon/hwmon2/temp1_input 2>/dev/null || echo 50000) / 1000 ))
LEARN_OFFSET=0
PROFILE="balanced"  # Fallback
CONF_MTIME=0        # Single mtime cache for unified conf
ERROR_COUNT=0       # Consecutive read errors
MAX_ERRORS=5        # Exit threshold

### --- Logging function (systemd journald compatible) ---
log() {
    local level="$1"
    shift
    logger -t zenfan -p "daemon.${level}" -- "$@"
}

### --- Cleanup on exit/term ---
cleanup() {
    log info "Shutting down: Restoring auto fan control"
    echo 2 > "$ENABLE" 2>/dev/null || true
    # Belt-and-suspenders: try tee as fallback
    echo 2 | tee "$ENABLE" > /dev/null 2>&1 || true
    rm -f "$STATE_FILE" 2>/dev/null || true
    exit 0
}
trap cleanup EXIT INT TERM ERR

### --- Safe file read with fallback ---
safe_read() {
    local file="$1" default="$2"
    if [[ -r "$file" ]]; then
        cat "$file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

### --- Get file mtime ---
get_mtime() {
    stat -c %Y "$1" 2>/dev/null || echo 0
}

### --- Load or reload unified config if changed ---
# Sources /etc/zenfan.conf which sets PROFILE, NIGHT_START, NIGHT_END.
# Uses a single mtime check — one cache for both values.
load_config() {
    local current_mtime
    current_mtime=$(get_mtime "$CONF")
    if [[ $current_mtime -ne $CONF_MTIME || $CONF_MTIME -eq 0 ]]; then
        if [[ -f "$CONF" ]]; then
            # shellcheck source=/etc/zenfan.conf
            source "$CONF" || log warning "Failed to source $CONF, using defaults"
        fi
        CONF_MTIME="$current_mtime"
        log info "Loaded config: profile=$PROFILE night=${NIGHT_START}-${NIGHT_END}"
    fi
}

### --- Persist state only if changed ---
persist_state() {
    local new_state="$LAST_PWM $LEARN_OFFSET $LAST_TEMP"
    local old_state
    old_state=$(safe_read "$STATE_FILE" "")
    if [[ "$new_state" != "$old_state" ]]; then
        echo "$new_state" > "$STATE_FILE" || log warning "Failed to write state"
    fi
}

### --- Initialization ---
log info "Starting Zenfan daemon"

# Check hardware interfaces
for file in "$PWM" "$ENABLE" "$TEMP"; do
    if [[ ! -w "$file" ]]; then
        log error "Hardware interface $file not writable. Exiting."
        exit 1
    fi
done

# Enable manual control
echo 1 > "$ENABLE" || { log error "Failed to enable manual control"; exit 1; }

# Ensure unified config exists with sane defaults
if [[ ! -f "$CONF" ]]; then
    printf 'PROFILE=balanced\nNIGHT_START=22\nNIGHT_END=7\n' > "$CONF" \
        || log warning "Failed to create config file"
fi

# Restore previous state
old_state=$(safe_read "$STATE_FILE" "")
if [[ -n "$old_state" ]]; then
    read -r LAST_PWM LEARN_OFFSET LAST_TEMP <<< "$old_state"
    log info "Restored state: PWM=$LAST_PWM, Offset=$LEARN_OFFSET, Temp=$LAST_TEMP"
fi

### --- Main control loop ---
while true; do
    echo 1 > "$ENABLE"  # Re-enable if needed (redundancy)

    # Load unified config if changed (profile + night schedule in one shot)
    load_config

    # Read temperature with retry/fallback
    RAW=$(cat "$TEMP" 2>/dev/null) || RAW=""
    if [[ -z "$RAW" ]]; then
        ((ERROR_COUNT++)) || true
        log warning "Failed to read temp (attempt $ERROR_COUNT)"
        if [[ $ERROR_COUNT -ge $MAX_ERRORS ]]; then
            log error "Too many read errors. Exiting."
            exit 1
        fi
        T="$LAST_TEMP"  # Fallback
    else
        ERROR_COUNT=0
        T=$((RAW / 1000))
    fi

    # Read load (1-min avg, integer)
    LOAD=$(awk '{print int($1)}' /proc/loadavg)

    ################################################################
    # Base thermal curves
    ################################################################
    case "$PROFILE" in
        quiet)
            LOW=55 MID=65 HIGH=75 MAX=85
            P1=30 P2=60 P3=100 P4=170 P5=210
            ;;
        performance)
            LOW=45 MID=55 HIGH=65 MAX=75
            P1=100 P2=140 P3=180 P4=210 P5=255
            ;;
        *)
            LOW=50 MID=60 HIGH=70 MAX=80
            P1=70 P2=100 P3=140 P4=180 P5=220
            ;;
    esac

    ################################################################
    # Adaptive learning offset
    ################################################################
    LOW=$((LOW - LEARN_OFFSET))
    MID=$((MID - LEARN_OFFSET))
    HIGH=$((HIGH - LEARN_OFFSET))
    MAX=$((MAX - LEARN_OFFSET))

    ################################################################
    # Temperature zone mapping with hysteresis
    ################################################################
    if (( T < LOW - HYST )); then
        TARGET=$P1
    elif (( T < MID - HYST )); then
        TARGET=$P2
    elif (( T < HIGH - HYST )); then
        TARGET=$P3
    elif (( T < MAX - HYST )); then
        TARGET=$P4
    else
        TARGET=$P5
    fi

    ################################################################
    # Load-based turbo boost
    ################################################################
    (( LOAD >= 3 )) && TARGET=$((TARGET + 25))

    ################################################################
    # Predictive throttling prevention
    ################################################################
    RISING=$((T - LAST_TEMP))
    if (( T >= THROTTLE_TEMP )); then
        TARGET=255
    elif (( T >= PREEMPT_TEMP && RISING >= 1 )); then
        TARGET=$FORCE_COOL_PWM
    elif (( RISING >= RAPID_RISE )); then
        TARGET=$((TARGET + 40))
    fi

    ################################################################
    # Safety clamp
    ################################################################
    (( TARGET > 255 )) && TARGET=255
    (( TARGET < 60 )) && TARGET=60

    ################################################################
    # Night acoustic limiter
    ################################################################
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

    # Manual override
    if [[ -f "$NIGHT_MODE_FILE" ]]; then
        MODE=$(safe_read "$NIGHT_MODE_FILE" "auto")
        [[ "$MODE" == "on" ]] && IN_NIGHT=1
        [[ "$MODE" == "off" ]] && IN_NIGHT=0
    fi

    # Apply quiet ceiling if safe
    if (( IN_NIGHT == 1 && T < NIGHT_OVERRIDE_TEMP )); then
        (( TARGET > NIGHT_MAX_PWM )) && TARGET=$NIGHT_MAX_PWM
    fi

    ################################################################
    # Smooth ramp control
    ################################################################
    DIFF=$((TARGET - LAST_PWM))
    ABS_DIFF=${DIFF#-}
    if (( ABS_DIFF > STEP )); then
        if (( DIFF > 0 )); then
            TARGET=$((LAST_PWM + STEP))
        else
            TARGET=$((LAST_PWM - STEP))
        fi
    fi

    ################################################################
    # Learning mechanism
    ################################################################
    if (( T > 75 )); then
        ((LEARN_OFFSET++)) || true
    elif (( T < 50 )); then
        ((LEARN_OFFSET--)) || true
    fi
    (( LEARN_OFFSET > MAX_OFFSET )) && LEARN_OFFSET=$MAX_OFFSET
    (( LEARN_OFFSET < -5 )) && LEARN_OFFSET=-5

    ################################################################
    # Persist state and apply fan speed
    ################################################################
    LAST_PWM=$TARGET
    LAST_TEMP=$T
    persist_state

    echo "$TARGET" > "$PWM" || log warning "Failed to set PWM"
    sleep 3
done
