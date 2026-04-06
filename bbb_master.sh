#!/usr/bin/env bash
# Master deployment script for BBBFlash.
# Syncs all BBB scripts to the target and optionally tests each one.
#
# Usage:
#   ./bbb_master.sh [--host <ssh-host>] [--test]
#
#   --host  SSH host alias or user@host (default: bbb)
#   --test  After syncing, run each script and verify it produces an output file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBB_HOST="bbb"
BBB_SCRIPT_DIR="/tmp/bbbflash"
RUN_TEST=0

# All managed scripts, in the order they should be synced.
SCRIPTS=(
    bbb_sysinfo.sh
    bbb_bluetooth.sh
)

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

log()  { printf '[INFO] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; }

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)  [[ $# -lt 2 ]] && { fail "--host requires a value"; exit 1; }
                 BBB_HOST="$2"; shift 2 ;;
        --test)  RUN_TEST=1; shift ;;
        -h|--help) usage ;;
        *) fail "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── SYNC ────────────────────────────────────────────────────────────────────

log "Target host: $BBB_HOST"
log "Syncing ${#SCRIPTS[@]} script(s) to ${BBB_HOST}:${BBB_SCRIPT_DIR}/"

ssh "$BBB_HOST" "mkdir -p '$BBB_SCRIPT_DIR'"

for script in "${SCRIPTS[@]}"; do
    src="$SCRIPT_DIR/$script"
    if [[ ! -f "$src" ]]; then
        fail "Script not found locally: $src"
        exit 1
    fi
    scp "$src" "${BBB_HOST}:${BBB_SCRIPT_DIR}/${script}" > /dev/null
    ssh "$BBB_HOST" "chmod +x '${BBB_SCRIPT_DIR}/${script}'"
    log "  Synced: $script"
done

log "Sync complete."

[[ $RUN_TEST -eq 0 ]] && exit 0

# ── TEST ─────────────────────────────────────────────────────────────────────

printf '\n'
log "Running tests..."

PASS=0
FAIL=0

for script in "${SCRIPTS[@]}"; do
    remote_script="${BBB_SCRIPT_DIR}/${script}"
    printf '\n[TEST] %s\n' "$script"

    # (1) Can the script execute?
    raw_output="$(ssh "$BBB_HOST" "bash '$remote_script'" 2>&1)"
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "Script exited with code $exit_code"
        FAIL=$((FAIL + 1))
        continue
    fi
    pass "Script executed (exit 0)"

    # (2) Did it produce an output file?
    # Scripts print the output path as the last line of stdout.
    outfile="$(printf '%s\n' "$raw_output" | tail -n1)"

    if [[ -z "$outfile" ]]; then
        fail "Could not determine output file path from script output"
        FAIL=$((FAIL + 1))
        continue
    fi

    file_exists="$(ssh "$BBB_HOST" "[[ -s '$outfile' ]] && echo yes || echo no")"
    if [[ "$file_exists" == "yes" ]]; then
        pass "Output file exists and is non-empty: $outfile"
        PASS=$((PASS + 1))
    else
        fail "Output file missing or empty: $outfile"
        FAIL=$((FAIL + 1))
    fi
done

printf '\n'
log "Results: $PASS passed, $FAIL failed."
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
