#!/usr/bin/env bash
# Master deployment script for BBBFlash.
# Syncs all BBB scripts to the target and optionally tests or runs one.
#
# Usage:
#   ./bbb_master.sh [--host <ssh-host>] [--test] [--run <name>] [--quiet]
#
#   --host   SSH host alias or user@host (default: bbb)
#   --test   After syncing, run each script and verify it produces an output file
#   --run    After syncing, run a single script by short name. Available names:
#              sysinfo      - collect CPU, memory, disk, network, OS details
#              bluetooth    - detect and report Bluetooth hardware
#              capabilities - GPIO, I2C, SPI, PWM, ADC, UART, CAN, pinmux
#   --quiet  Suppress [INFO] log lines (errors and test results still shown)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_OUTPUT_DIR="$SCRIPT_DIR/output"
BBB_HOST="bbb"
BBB_SCRIPT_DIR="/home/debian/bbbflash"
RUN_TEST=0
RUN_TARGET=""
QUIET=0

# All managed scripts, in the order they should be synced.
# Format: "shortname:filename"
SCRIPTS=(
    "sysinfo:bbb_sysinfo.sh"
    "bluetooth:bbb_bluetooth.sh"
    "capabilities:bbb_capabilities.sh"
)

usage() {
    # Print the leading comment block (stops at first non-comment line).
    awk 'NR==1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
}

log()  { [[ $QUIET -eq 0 ]] && printf '[%s] [INFO] %s\n' "$(date +%H:%M:%S)" "$*" || true; }
pass() { printf '[%s] [PASS] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] [FAIL] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

resolve_script() {
    local name="$1"
    for entry in "${SCRIPTS[@]}"; do
        local short="${entry%%:*}"
        local file="${entry##*:}"
        if [[ "$short" == "$name" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    fail "Unknown script name: '$name'"
    printf 'Available names:\n' >&2
    for entry in "${SCRIPTS[@]}"; do
        printf '  %s\n' "${entry%%:*}" >&2
    done
    exit 1
}

fetch_output() {
    local remote_path="$1"
    local filename
    filename="$(basename "$remote_path")"
    mkdir -p "$LOCAL_OUTPUT_DIR"
    log "Fetching output file: $filename"
    scp -q "${BBB_HOST}:${remote_path}" "${LOCAL_OUTPUT_DIR}/${filename}"
    log "Saved to: ${LOCAL_OUTPUT_DIR}/${filename}"
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)  [[ $# -lt 2 ]] && { fail "--host requires a value"; exit 1; }
                 BBB_HOST="$2"; shift 2 ;;
        --test)  RUN_TEST=1; shift ;;
        --run)   [[ $# -lt 2 ]] && { fail "--run requires a script name"; exit 1; }
                 RUN_TARGET="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage ;;
        *) fail "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── SYNC ────────────────────────────────────────────────────────────────────

log "Target host: $BBB_HOST"
log "Ensuring remote directory exists: $BBB_SCRIPT_DIR"
ssh -q "$BBB_HOST" "mkdir -p '$BBB_SCRIPT_DIR'"

log "Syncing ${#SCRIPTS[@]} script(s) to ${BBB_HOST}:${BBB_SCRIPT_DIR}/"

for entry in "${SCRIPTS[@]}"; do
    script="${entry##*:}"
    src="$SCRIPT_DIR/$script"
    if [[ ! -f "$src" ]]; then
        fail "Script not found locally: $src"
        exit 1
    fi
    log "  Copying: $script"
    scp -q "$src" "${BBB_HOST}:${BBB_SCRIPT_DIR}/${script}"
    ssh -q "$BBB_HOST" "chmod +x '${BBB_SCRIPT_DIR}/${script}'"
    log "  Ready:   $script"
done

log "Sync complete."

[[ $RUN_TEST -eq 0 && -z "$RUN_TARGET" ]] && exit 0

# ── RUN ──────────────────────────────────────────────────────────────────────

run_script() {
    local script="$1"
    local remote_script="${BBB_SCRIPT_DIR}/${script}"
    local tmp_out
    tmp_out="$(mktemp)"
    printf '\n'
    log "── Running: $script on $BBB_HOST"
    ssh -q "$BBB_HOST" "bash '$remote_script'" 2>&1 | tee "$tmp_out"
    local exit_code=${PIPESTATUS[0]}
    local outfile
    outfile="$(tail -n1 "$tmp_out")"
    rm -f "$tmp_out"
    if [[ $exit_code -eq 0 && -n "$outfile" ]]; then
        fetch_output "$outfile"
    fi
    return $exit_code
}

if [[ -n "$RUN_TARGET" ]]; then
    script="$(resolve_script "$RUN_TARGET")"
    run_script "$script"
    exit $?
fi

# ── TEST ─────────────────────────────────────────────────────────────────────

printf '\n'
log "Running tests..."

PASS=0
FAIL=0

for entry in "${SCRIPTS[@]}"; do
    script="${entry##*:}"
    remote_script="${BBB_SCRIPT_DIR}/${script}"
    printf '\n'
    log "── Testing: $script"

    # (1) Run the script, streaming output live; capture to temp file for path extraction.
    tmp_out="$(mktemp)"
    log "Executing on $BBB_HOST..."
    ssh -q "$BBB_HOST" "bash '$remote_script'" 2>&1 | tee "$tmp_out"
    exit_code=${PIPESTATUS[0]}

    if [[ $exit_code -ne 0 ]]; then
        fail "Script exited with code $exit_code"
        rm -f "$tmp_out"
        FAIL=$((FAIL + 1))
        continue
    fi
    pass "Script executed (exit 0)"

    # (2) Did it produce an output file?
    # Scripts print the output path as the last line of stdout.
    outfile="$(tail -n1 "$tmp_out")"
    rm -f "$tmp_out"

    if [[ -z "$outfile" ]]; then
        fail "Could not determine output file path from script output"
        FAIL=$((FAIL + 1))
        continue
    fi

    log "Verifying output file: $outfile"
    file_exists="$(ssh -q "$BBB_HOST" "[[ -s '$outfile' ]] && echo yes || echo no")"
    if [[ "$file_exists" == "yes" ]]; then
        pass "Output file exists and is non-empty: $outfile"
        fetch_output "$outfile"
        PASS=$((PASS + 1))
    else
        fail "Output file missing or empty: $outfile"
        FAIL=$((FAIL + 1))
    fi
done

printf '\n'
log "Results: $PASS passed, $FAIL failed."
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
