#!/usr/bin/env bash
# Collects basic system information from a BeagleBone Black.
# Output is written to /tmp/bbb_sysinfo_<timestamp>.txt

set -euo pipefail

OUTFILE="/tmp/bbb_sysinfo_$(date +%Y%m%d_%H%M%S).txt"

section() {
    printf '\n==================================================\n' >> "$OUTFILE"
    printf '%s\n' "$1" >> "$OUTFILE"
    printf '==================================================\n' >> "$OUTFILE"
}

run() {
    section "$1"
    eval "$2" >> "$OUTFILE" 2>&1 || true
}

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

printf '\n[INFO] Report written to: %s\n' "$OUTFILE"
printf '%s\n' "$OUTFILE"
