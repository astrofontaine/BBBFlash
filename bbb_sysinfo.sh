#!/usr/bin/env bash
# Collects basic system information from a BeagleBone Black.
# Output is written to /home/debian/bbb_sysinfo_<timestamp>.txt

set -euo pipefail

OUTFILE="/home/debian/bbb_sysinfo_$(date +%Y%m%d_%H%M%S).txt"

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

log "Starting sysinfo collection"
log "Output file: $OUTFILE"

: > "$OUTFILE"

printf 'BBB System Info Report\n' >> "$OUTFILE"
printf 'Generated: %s\n' "$(date -Iseconds)" >> "$OUTFILE"
printf 'Hostname:  %s\n' "$(hostname)" >> "$OUTFILE"

run "CPU INFO (lscpu)"        "lscpu"
run "MEMORY (free -h)"        "free -h"
run "DISK USAGE (df -h)"      "df -h"
run "NETWORK (ip address)"    "ip address"
run "OS RELEASE"              "cat /etc/os-release"
run "KERNEL"                  "uname -a"
run "UPTIME"                  "uptime"

log "Collection complete. Report written to: $OUTFILE"
printf '%s\n' "$OUTFILE"
