#!/usr/bin/env bash
# Inventories all files on the BeagleBone Black, categorised by purpose.
# Requires root. Pass SUDO_PASS env var or run as root directly.
# Output is written to /home/debian/bbb_filesystem_<timestamp>.txt

set -euo pipefail

# ── Root escalation ───────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    if [[ -z "${SUDO_PASS:-}" ]]; then
        echo "[ERROR] Not root and SUDO_PASS not set. Run via bbb_master.sh or as root." >&2
        exit 1
    fi
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' bash "$0" "$@"
    exit $?
fi

OUTFILE="/home/debian/bbb_filesystem_$(date +%Y%m%d_%H%M%S).txt"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

section() {
    printf '\n==================================================\n' >> "$OUTFILE"
    printf '%s\n' "$1" >> "$OUTFILE"
    printf '==================================================\n' >> "$OUTFILE"
}

# Print a category block: summary + full find -ls listing.
# Usage: category <title> <path> [<path> ...]
category() {
    local title="$1"; shift
    local paths=("$@")

    log "Running: $title"
    section "$title"

    printf 'Paths:      %s\n' "${paths[*]}" >> "$OUTFILE"
    printf 'Disk usage: %s\n' "$(du -shc "${paths[@]}" 2>/dev/null | tail -1 | cut -f1)" >> "$OUTFILE"
    printf 'File count: %s\n\n' "$(find "${paths[@]}" -xdev -type f 2>/dev/null | wc -l)" >> "$OUTFILE"

    # Columns: permissions owner group size date name
    find "${paths[@]}" -xdev -type f -ls 2>/dev/null \
        | awk '{printf "%-12s %-10s %-10s %8s  %s %s %s  %s\n", $3,$5,$6,$7,$8,$9,$10,$11}' \
        | sort -k8 \
        >> "$OUTFILE" || true

    log "Done:    $title"
}

: > "$OUTFILE"

log "Starting filesystem inventory (running as $(whoami))"
log "Output file: $OUTFILE"

printf 'BBB Filesystem Inventory\n'   >> "$OUTFILE"
printf 'Generated: %s\n' "$(date -Iseconds)" >> "$OUTFILE"
printf 'Hostname:  %s\n' "$(hostname)" >> "$OUTFILE"
printf 'Run as:    %s\n' "$(whoami)"   >> "$OUTFILE"

# ── OVERALL SUMMARY ──────────────────────────────────────────────────────────
log "Running: OVERALL SUMMARY"
section "OVERALL SUMMARY"
{
    printf 'Filesystem usage:\n'
    df -h --exclude-type=tmpfs --exclude-type=devtmpfs 2>/dev/null || df -h
    printf '\nTop-level directory sizes (real fs only):\n'
    du -shx /* 2>/dev/null | sort -h || true
    printf '\nTotal real files (excluding /proc /sys /dev /run):\n'
    find / -xdev -not -path '/proc/*' -not -path '/sys/*' \
           -not -path '/dev/*'  -not -path '/run/*' \
           -type f 2>/dev/null | wc -l
} >> "$OUTFILE"
log "Done:    OVERALL SUMMARY"

# ── FILE CATEGORIES ───────────────────────────────────────────────────────────

category "BOOT & KERNEL"          /boot
category "FIRMWARE & OVERLAYS"    /lib/firmware
category "EXECUTABLES"            /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin
category "LIBRARIES"              /lib /usr/lib /usr/local/lib
category "CONFIGURATION"          /etc
category "SYSTEMD UNITS"          /lib/systemd /etc/systemd
category "LOGS"                   /var/log
category "SYSTEM DATA"            /var/lib /var/cache /var/spool
category "USER FILES"             /home /root
category "TEMPORARY FILES"        /tmp /var/tmp
category "SCRIPTS & TOOLS (opt)"  /opt

# ── SPECIAL FILE REPORTS ─────────────────────────────────────────────────────
log "Running: SETUID / SETGID FILES"
section "SETUID / SETGID FILES"
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -ls 2>/dev/null \
    | awk '{printf "%-12s %-10s %-10s %8s  %s %s %s  %s\n", $3,$5,$6,$7,$8,$9,$10,$11}' \
    >> "$OUTFILE" || true
log "Done:    SETUID / SETGID FILES"

log "Running: WORLD-WRITABLE FILES"
section "WORLD-WRITABLE FILES"
find / -xdev -perm -o+w -not -type l -type f -ls 2>/dev/null \
    | awk '{printf "%-12s %-10s %-10s %8s  %s %s %s  %s\n", $3,$5,$6,$7,$8,$9,$10,$11}' \
    >> "$OUTFILE" || true
log "Done:    WORLD-WRITABLE FILES"

log "Running: LARGEST FILES (top 40)"
section "LARGEST FILES (top 40)"
find / -xdev -not -path '/proc/*' -not -path '/sys/*' \
       -not -path '/dev/*'  -not -path '/run/*' \
       -type f -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -40 \
    | awk '{printf "%12s  %s\n", $1, $2}' \
    >> "$OUTFILE" || true
log "Done:    LARGEST FILES (top 40)"

log "Running: RECENTLY MODIFIED FILES (last 7 days)"
section "RECENTLY MODIFIED FILES (last 7 days)"
find / -xdev -not -path '/proc/*' -not -path '/sys/*' \
       -not -path '/dev/*'  -not -path '/run/*' \
       -type f -mtime -7 -ls 2>/dev/null \
    | awk '{printf "%-12s %-10s %-10s %8s  %s %s %s  %s\n", $3,$5,$6,$7,$8,$9,$10,$11}' \
    | sort -k8 \
    >> "$OUTFILE" || true
log "Done:    RECENTLY MODIFIED FILES (last 7 days)"

log "Collection complete. Report written to: $OUTFILE"
printf '%s\n' "$OUTFILE"
