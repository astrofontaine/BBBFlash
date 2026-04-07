# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

BBBFlash remotely inspects a BeagleBone Black (BBB) over SSH. `bbb_master.sh` syncs collection scripts to the BBB, executes them, and SCP-fetches their output. Each collection script runs on the BBB, writes a timestamped report to `/home/debian/`, and prints the report path as its last stdout line.

## Running

```bash
# Sync only
./bbb_master.sh

# Run one script and fetch output
./bbb_master.sh --run sysinfo
./bbb_master.sh --run bluetooth
./bbb_master.sh --run capabilities
./bbb_master.sh --run filesystem      # requires sudo on BBB

# Test all scripts
./bbb_master.sh --test

# Suppress INFO logs
./bbb_master.sh --run sysinfo --quiet

# Pre-supply sudo password non-interactively
BBB_SUDO_PASS=yourpassword ./bbb_master.sh --run filesystem
```

## SSH connectivity

- `ssh bbb` must connect without a password (key-based auth configured)
- The BBB reaches back as `ssh claude` for push-mode SCP
- All SSH/SCP calls use `-q` to suppress the BBB's login banner

## Architecture

`bbb_master.sh` is the only script run locally. It:
1. Syncs all `SCRIPTS` entries to `bbb:/home/debian/bbbflash/` via SCP
2. Executes each via `ssh -q bbb "bash <script>"`, streaming stdout live via `tee`
3. Reads the last stdout line as the remote output file path (`OUTFILE_PATH` global)
4. SCPs that file back to `./output/`

For scripts with `sudo` flag, the BBB sudo password is passed via SSH stdin:
```
printf '%s\n' "$BBB_SUDO_PASS" | ssh -q bbb "read -rs SUDO_PASS && export SUDO_PASS && bash <script>"
```
The collection script then does `printf '%s\n' "$SUDO_PASS" | sudo -S -p '' bash "$0"` to re-exec as root.

## SCRIPTS array format

```bash
"shortname|filename|sudo_flag|description"
```

`script_info()` in `bbb_master.sh` derives file size (`du -sh`) and last-updated date (`git log`) dynamically at runtime and logs them per script.

## Adding a new collection script

1. Create `bbb_<name>.sh` using the pattern from any existing script:
   - `OUTFILE="/home/debian/bbb_<name>_$(date +%Y%m%d_%H%M%S).txt"`
   - Use `log()`, `section()`, `run()` helpers
   - Final stdout line must be `printf '%s\n' "$OUTFILE"`
2. Add to `SCRIPTS` array in `bbb_master.sh`
3. Update the `--run` list in the usage comment block at the top

## Output files

Collected to `./output/` (gitignored). Never committed. Format: `bbb_<name>_<YYYYMMDD_HHMMSS>.txt`.
