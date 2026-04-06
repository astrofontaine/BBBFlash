#!/usr/bin/env bash
# Collects hardware pin and peripheral capability information from a BeagleBone Black.
# Covers GPIO, I2C, SPI, PWM, ADC, UART, CAN, pinmux, device tree, and cape EEPROMs.
# Output is written to /home/debian/bbb_capabilities_<timestamp>.txt

set -euo pipefail

OUTFILE="/home/debian/bbb_capabilities_$(date +%Y%m%d_%H%M%S).txt"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

section() {
    printf '\n==================================================\n' >> "$OUTFILE"
    printf '%s\n' "$1" >> "$OUTFILE"
    printf '==================================================\n' >> "$OUTFILE"
}

run() {
    log "Running: $1"
    section "$1"
    eval "$2" >> "$OUTFILE" 2>&1 || true
    log "Done:    $1"
}

log "Starting capabilities collection"
log "Output file: $OUTFILE"

: > "$OUTFILE"

printf 'BBB Hardware Capabilities Report\n' >> "$OUTFILE"
printf 'Generated: %s\n' "$(date -Iseconds)" >> "$OUTFILE"
printf 'Hostname:  %s\n' "$(hostname)" >> "$OUTFILE"

# ── BOARD IDENTITY ───────────────────────────────────────────────────────────
run "BOARD MODEL" \
    "cat /proc/device-tree/model 2>/dev/null || cat /sys/firmware/devicetree/base/model 2>/dev/null || echo 'not found'"

run "BOARD IMAGE (dogtag)" \
    "cat /etc/dogtag 2>/dev/null || echo 'not found'"

run "CPU INFO" \
    "grep -E 'Hardware|Revision|Serial' /proc/cpuinfo || true"

run "KERNEL" \
    "uname -a"

run "BOOT OVERLAYS (/boot/uEnv.txt)" \
    "grep -E 'overlay|cape' /boot/uEnv.txt 2>/dev/null || echo 'none or file not found'"

run "ACTIVE DEVICE TREE OVERLAYS" \
    "cat /sys/firmware/devicetree/base/chosen/overlays 2>/dev/null | strings || echo 'none active'"

# ── GPIO ─────────────────────────────────────────────────────────────────────
run "GPIO CHIPS" \
    "for d in /sys/class/gpio/gpiochip*/; do
         label=\$(cat \"\$d/label\" 2>/dev/null)
         base=\$(cat \"\$d/base\" 2>/dev/null)
         ngpio=\$(cat \"\$d/ngpio\" 2>/dev/null)
         printf 'chip=%s  base=%s  ngpio=%s  label=%s\n' \"\$(basename \$d)\" \"\$base\" \"\$ngpio\" \"\$label\"
     done"

run "GPIO EXPORTED PINS" \
    "exported=\$(ls /sys/class/gpio/ | grep -v gpiochip || true)
     if [[ -z \"\$exported\" ]]; then echo 'none exported'; else
         for g in \$exported; do
             dir=\$(cat /sys/class/gpio/\$g/direction 2>/dev/null)
             val=\$(cat /sys/class/gpio/\$g/value 2>/dev/null)
             printf '%s  direction=%s  value=%s\n' \"\$g\" \"\$dir\" \"\$val\"
         done
     fi"

run "GPIOINFO (libgpiod)" \
    "gpioinfo 2>/dev/null || echo 'gpioinfo not available (libgpiod-tools not installed)'"

# ── PIN MUX ──────────────────────────────────────────────────────────────────
run "PINCTRL PINS (44e10800.pinmux)" \
    "cat /sys/kernel/debug/pinctrl/44e10800.pinmux/pins 2>/dev/null || echo 'debugfs not available or pinctrl path differs'"

run "PINCTRL PIN GROUPS" \
    "cat /sys/kernel/debug/pinctrl/44e10800.pinmux/pingroups 2>/dev/null || echo 'not available'"

run "CONFIG-PIN LIST" \
    "config-pin -l 2>/dev/null || echo 'config-pin not installed'"

# ── I2C ──────────────────────────────────────────────────────────────────────
run "I2C BUSES" \
    "for b in /sys/class/i2c-adapter/i2c-*/; do
         name=\$(cat \"\$b/name\" 2>/dev/null)
         printf '%s: %s\n' \"\$(basename \$b)\" \"\$name\"
     done"

run "I2C DEVICES (i2cdetect -l)" \
    "i2cdetect -l 2>/dev/null || echo 'i2cdetect not available'"

run "I2C BUS SCAN (i2cdetect -y -r)" \
    "for i in 0 1 2; do
         printf '\n--- i2c-%d ---\n' \"\$i\"
         i2cdetect -y -r \"\$i\" 2>/dev/null || echo 'bus not available'
     done"

run "I2C SYSFS DEVICES" \
    "ls /sys/bus/i2c/devices/ 2>/dev/null || echo 'none'"

# ── SPI ──────────────────────────────────────────────────────────────────────
run "SPI CONTROLLERS" \
    "for s in /sys/class/spi_master/spi*/; do
         ncs=\$(cat \"\$s/num_chipselect\" 2>/dev/null || echo '?')
         printf '%s  num_chipselect=%s\n' \"\$(basename \$s)\" \"\$ncs\"
     done 2>/dev/null || echo 'none found'"

run "SPI DEVICES" \
    "ls /sys/bus/spi/devices/ 2>/dev/null || echo 'none'"

run "SPI DEV NODES" \
    "ls /dev/spidev* 2>/dev/null || echo 'none (overlays may be needed)'"

# ── PWM ──────────────────────────────────────────────────────────────────────
run "PWM CHIPS" \
    "for p in /sys/class/pwm/pwmchip*/; do
         npwm=\$(cat \"\$p/npwm\" 2>/dev/null || echo '?')
         printf '%s  npwm=%s\n' \"\$(basename \$p)\" \"\$npwm\"
     done 2>/dev/null || echo 'none found'"

run "PWM CHANNELS (exported)" \
    "find /sys/class/pwm/ -name 'pwm[0-9]*' -maxdepth 2 2>/dev/null | while read ch; do
         period=\$(cat \"\$ch/period\" 2>/dev/null || echo '?')
         duty=\$(cat \"\$ch/duty_cycle\" 2>/dev/null || echo '?')
         enabled=\$(cat \"\$ch/enable\" 2>/dev/null || echo '?')
         printf '%s  period=%s  duty_cycle=%s  enable=%s\n' \"\$(basename \$ch)\" \"\$period\" \"\$duty\" \"\$enabled\"
     done || echo 'none exported'"

# ── ADC ──────────────────────────────────────────────────────────────────────
run "ADC (IIO) DEVICES" \
    "for d in /sys/bus/iio/devices/iio:device*/; do
         name=\$(cat \"\$d/name\" 2>/dev/null || echo '?')
         printf '\nDevice: %s  name=%s\n' \"\$(basename \$d)\" \"\$name\"
         for ch in \"\$d\"in_voltage*_raw; do
             [[ -f \"\$ch\" ]] && printf '  %s = %s\n' \"\$(basename \$ch)\" \"\$(cat \$ch 2>/dev/null)\"
         done
     done 2>/dev/null || echo 'no IIO devices found (BB-ADC overlay may be needed)'"

# ── UART ─────────────────────────────────────────────────────────────────────
run "UART / SERIAL DEVICES" \
    "ls -1 /dev/ttyO* /dev/ttyS* 2>/dev/null || echo 'none found'"

run "SERIAL TTY DRIVERS" \
    "cat /proc/tty/drivers 2>/dev/null | grep -i 'serial\|uart\|omap' || echo 'not found'"

run "UART PLATFORM DEVICES" \
    "ls /sys/bus/platform/devices/ | grep -i 'uart\|serial\|48[0-9]' || echo 'none matched'"

# ── CAN ──────────────────────────────────────────────────────────────────────
run "CAN INTERFACES" \
    "ip link show type can 2>/dev/null || ls /sys/class/net/ | grep '^can' 2>/dev/null || echo 'no CAN interfaces found'"

run "CAN PLATFORM DEVICES" \
    "ls /sys/bus/platform/devices/ | grep -i 'can\|481' || echo 'none matched'"

# ── CAPE EEPROM ───────────────────────────────────────────────────────────────
run "CAPE EEPROM DEVICES" \
    "ls /sys/bus/i2c/devices/1-005*/eeprom /sys/bus/i2c/devices/2-005*/eeprom 2>/dev/null || echo 'no cape EEPROMs found at standard addresses'"

run "CAPE EEPROM CONTENTS (first 32 bytes each)" \
    "for eeprom in /sys/bus/i2c/devices/1-005*/eeprom /sys/bus/i2c/devices/2-005*/eeprom; do
         [[ -f \"\$eeprom\" ]] || continue
         printf '\n%s:\n' \"\$eeprom\"
         hexdump -C \"\$eeprom\" 2>/dev/null | head -4 || echo 'unreadable'
     done || echo 'none'"

run "BOARD EEPROM (i2c-0 0x50, first 32 bytes)" \
    "hexdump -C /sys/bus/i2c/devices/0-0050/eeprom 2>/dev/null | head -4 || echo 'not available'"

# ── MISC PERIPHERALS ─────────────────────────────────────────────────────────
run "HARDWARE MONITORING (hwmon)" \
    "for h in /sys/class/hwmon/hwmon*/; do
         name=\$(cat \"\$h/name\" 2>/dev/null || echo '?')
         printf '%s: %s\n' \"\$(basename \$h)\" \"\$name\"
     done 2>/dev/null || echo 'none'"

run "PLATFORM DEVICES (full list)" \
    "ls /sys/bus/platform/devices/"

run "LOADED KERNEL MODULES" \
    "lsmod | sort"

log "Collection complete. Report written to: $OUTFILE"
printf '%s\n' "$OUTFILE"
