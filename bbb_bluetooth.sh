#!/usr/bin/env bash
# Detects and reports Bluetooth hardware details on a BeagleBone Black.
# Output is written to /home/debian/bbb_bluetooth_<timestamp>.txt

set -euo pipefail

OUTFILE="/home/debian/bbb_bluetooth_$(date +%Y%m%d_%H%M%S).txt"

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

log "Starting Bluetooth detection"
log "Output file: $OUTFILE"

: > "$OUTFILE"

printf 'BBB Bluetooth Hardware Report\n' >> "$OUTFILE"
printf 'Generated: %s\n' "$(date -Iseconds)" >> "$OUTFILE"
printf 'Hostname:  %s\n' "$(hostname)" >> "$OUTFILE"

run "BLUETOOTH KERNEL MODULES"     "lsmod | grep -i bt\|bluetooth\|hci\|wilink\|wl18xx\|wlcore\|ti_wl18"
run "DMESG (bluetooth)"            "dmesg | grep -i 'bluetooth\|hci\|wilink\|wl18\|brcm\|btusb\|btsdio'"
run "RFKILL LIST"                  "rfkill list"
run "HCI DEVICES (hciconfig -a)"   "hciconfig -a"
run "USB DEVICES (lsusb)"          "lsusb"
run "SDIO / MMC DEVICES"           "cat /sys/bus/sdio/devices/*/modalias 2>/dev/null || echo 'none found'"
run "BLUETOOTH SYSFS"              "find /sys -name '*bluetooth*' -o -name '*hci*' 2>/dev/null | head -40"
run "PLATFORM DEVICES"             "ls /sys/bus/platform/devices/ 2>/dev/null | grep -i 'bt\|wilink\|wl18' || echo 'none matched'"
run "LOADED BT FIRMWARE"           "ls /lib/firmware/ti-connectivity/ 2>/dev/null || ls /lib/firmware/ 2>/dev/null | grep -i 'bt\|wilink\|wl18' || echo 'none found'"
run "BLUETOOTHCTL INFO"            "timeout 5 bluetoothctl show 2>/dev/null || echo 'bluetoothctl not available or timed out'"
run "SERVICE STATUS"               "systemctl status bluetooth.service 2>/dev/null || echo 'systemctl not available'"

log "Detection complete. Report written to: $OUTFILE"
printf '%s\n' "$OUTFILE"
