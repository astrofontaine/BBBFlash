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
#              filesystem   - full file inventory by category (requires sudo)
#   --quiet  Suppress [INFO] log lines (errors and test results still shown)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_OUTPUT_DIR="$SCRIPT_DIR/output"
BBB_HOST="bbb"
BBB_SCRIPT_DIR="/home/debian/bbbflash"
RUN_TEST=0
RUN_TARGET=""
QUIET=0
BBB_SUDO_PASS="${BBB_SUDO_PASS:-}"

# All managed scripts, in the order they should be synced.
# Format: "shortname:filename:needs_sudo"
SCRIPTS=(
    "sysinfo:bbb_sysinfo.sh:no"
    "bluetooth:bbb_bluetooth.sh:no"
    "capabilities:bbb_capabilities.sh:no"
    "filesystem:bbb_filesystem.sh:sudo"
)

usage() {
    awk 'NR==1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
}

log()  { [[ $QUIET -eq 0 ]] && printf '[%s] [INFO] %s\n' "$(date +%H:%M:%S)" "$*" || true; }
pass() { printf '[%s] [PASS] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] [FAIL] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

resolve_entry() {
    local name="$1"
    for entry in "${SCRIPTS[@]}"; do
        local short="${entry%%:*}"
        if [[ "$short" == "$name" ]]; then
            printf '%s\n' "$entry"
            return 0
        fi
    done
    fail "Unknown script name: '$name'"
    printf 'Available names:\n' >&2
    for entry in "${SCRIPTS[@]}"; do
        printf '  %-14s %s\n' "${entry%%:*}" \
            "$(printf '%s' "$entry" | cut -d: -f3 | grep -q sudo && echo '(requires sudo)' || true)" >&2
    done
    exit 1
}

# Prompt for BBB sudo password once; cached for the session.
# Must be called outside any subshell so BBB_SUDO_PASS propagates.
prompt_sudo() {
    if [[ -n "$BBB_SUDO_PASS" ]]; then return; fi
    log "Script requires sudo on the BBB."
    if [[ -t 0 ]]; then
        read -r -s -p "         Enter sudo password for BBB: " BBB_SUDO_PASS
        printf '\n'
    else
        read -r BBB_SUDO_PASS || true
    fi
    if [[ -z "$BBB_SUDO_PASS" ]]; then
        fail "No sudo password provided."
        exit 1
    fi
}

# Run a script on the BBB, streaming output live.
# Writes the remote output file path to OUTFILE_PATH (global).
# Usage: ssh_run <script_filename> <needs_sudo>
OUTFILE_PATH=""
ssh_run() {
    local script="$1"
    local needs_sudo="$2"
    local remote_script="${BBB_SCRIPT_DIR}/${script}"
    local tmp_out
    tmp_out="$(mktemp)"

    if [[ "$needs_sudo" == "sudo" ]]; then
        # Pass password as first stdin line; remote shell reads it into SUDO_PASS.
        printf '%s\n' "$BBB_SUDO_PASS" \
            | ssh -q "$BBB_HOST" \
                "read -rs SUDO_PASS && export SUDO_PASS && bash '$remote_script'" \
                2>&1 | tee "$tmp_out"
    else
        ssh -q "$BBB_HOST" "bash '$remote_script'" 2>&1 | tee "$tmp_out"
    fi

    local exit_code=${PIPESTATUS[0]}
    OUTFILE_PATH="$(tail -n1 "$tmp_out")"
    rm -f "$tmp_out"
    return $exit_code
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
    script="$(printf '%s' "$entry" | cut -d: -f2)"
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

if [[ -n "$RUN_TARGET" ]]; then
    entry="$(resolve_entry "$RUN_TARGET")"
    script="$(printf '%s' "$entry" | cut -d: -f2)"
    needs_sudo="$(printf '%s' "$entry" | cut -d: -f3)"
    [[ "$needs_sudo" == "sudo" ]] && prompt_sudo
    printf '\n'
    log "── Running: $script on $BBB_HOST"
    ssh_run "$script" "$needs_sudo"
    rc=$?
    if [[ $rc -eq 0 && -n "$OUTFILE_PATH" ]]; then
        fetch_output "$OUTFILE_PATH"
    fi
    exit $rc
fi

# ── TEST ─────────────────────────────────────────────────────────────────────

printf '\n'
log "Running tests..."

PASS=0
FAIL=0

for entry in "${SCRIPTS[@]}"; do
    script="$(printf '%s' "$entry" | cut -d: -f2)"
    needs_sudo="$(printf '%s' "$entry" | cut -d: -f3)"
    [[ "$needs_sudo" == "sudo" ]] && prompt_sudo
    printf '\n'
    log "── Testing: $script"
    log "Executing on $BBB_HOST..."

    ssh_run "$script" "$needs_sudo"
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "Script exited with code $exit_code"
        FAIL=$((FAIL + 1))
        continue
    fi
    pass "Script executed (exit 0)"

    if [[ -z "$OUTFILE_PATH" ]]; then
        fail "Could not determine output file path from script output"
        FAIL=$((FAIL + 1))
        continue
    fi

    log "Verifying output file: $OUTFILE_PATH"
    file_exists="$(ssh -q "$BBB_HOST" "[[ -s '$OUTFILE_PATH' ]] && echo yes || echo no")"
    if [[ "$file_exists" == "yes" ]]; then
        pass "Output file exists and is non-empty: $OUTFILE_PATH"
        fetch_output "$OUTFILE_PATH"
        PASS=$((PASS + 1))
    else
        fail "Output file missing or empty: $OUTFILE_PATH"
        FAIL=$((FAIL + 1))
    fi
done

printf '\n'
log "Results: $PASS passed, $FAIL failed."
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
