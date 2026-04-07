# BBBFlash

A collection of Bash scripts for remotely inspecting and eventually updating a **BeagleBone Black (BBB)** over SSH. The master script manages deployment, execution, and retrieval of output from all collection scripts in a single command.

---

## Architecture

```
Local machine (claude)              BeagleBone Black
─────────────────────               ─────────────────
bbb_master.sh                       /home/debian/bbbflash/
  │                                   bbb_sysinfo.sh
  ├─ scp scripts ──────────────────►  bbb_bluetooth.sh
  │                                   bbb_capabilities.sh
  ├─ ssh + execute ────────────────►  bbb_filesystem.sh
  │                                       │
  │                                       └─ writes output to
  │                                          /home/debian/bbb_<name>_<timestamp>.txt
  │
  └─ scp output ◄──────────────────   /home/debian/bbb_*.txt
       │
       └─ saved to ./output/
```

Every collection script follows the same contract:
- Runs on the BBB
- Writes a timestamped report to `/home/debian/`
- Prints the output file path as its final stdout line (used by master for SCP retrieval)
- Logs timestamped `[HH:MM:SS]` progress to stdout as it works

---

## Prerequisites

- SSH key authentication configured: `ssh bbb` must connect without a password
- The reverse path (`ssh claude` from the BBB) must also work for push-mode SCP
- `git` on the local machine (used by master to derive script last-updated dates)
- No additional packages required on the BBB beyond what ships with the Debian Buster IoT image

---

## Usage

### Sync all scripts to BBB (no execution)
```bash
./bbb_master.sh
```

### Run a single script and retrieve output
```bash
./bbb_master.sh --run sysinfo
./bbb_master.sh --run bluetooth
./bbb_master.sh --run capabilities
./bbb_master.sh --run filesystem       # prompts for BBB sudo password
```

### Test all scripts (run + verify output file produced)
```bash
./bbb_master.sh --test
```

### Options
```
--host <ssh-host>   Override BBB SSH target (default: bbb)
--run  <name>       Run a single script by short name after syncing
--test              Run all scripts and verify each produces an output file
--quiet             Suppress [INFO] log lines (errors and pass/fail still shown)
-h / --help         Show usage
```

### Sudo password
Scripts that require root (currently `filesystem`) prompt interactively. To avoid
the prompt in non-interactive contexts, pre-set the variable:
```bash
BBB_SUDO_PASS=yourpassword ./bbb_master.sh --run filesystem
```

---

## Scripts

### `bbb_master.sh`
The orchestrator. Syncs all scripts to the BBB, optionally runs or tests them,
and SCP-fetches any output files to `./output/`. Maintains a `SCRIPTS` array
where each entry carries the short name, filename, sudo flag, and description.
Script metadata (size, last git commit date) is logged at runtime.

### `bbb_sysinfo.sh`
Collects general system information: CPU (lscpu), memory, disk usage, network
interfaces, OS release, kernel version, and uptime.

### `bbb_bluetooth.sh`
Detects Bluetooth hardware: kernel modules, dmesg entries, rfkill state, HCI
devices, USB devices, SDIO devices, sysfs paths, available TI WiLink firmware,
bluetoothctl adapter info, and bluetooth service status.

### `bbb_capabilities.sh`
Full hardware peripheral inventory: board identity and EEPROM, GPIO chips and
all 128 lines (with P8/P9 header mapping via gpioinfo), pinctrl/pinmux state,
I2C buses and device scan, SPI controllers and dev nodes, PWM chips and
channels, ADC (all 8 AIN channels via IIO), UART/serial devices, CAN
interfaces, cape EEPROMs, hardware monitoring, platform devices, and loaded
kernel modules.

### `bbb_filesystem.sh`
Root-level file inventory categorised by purpose. Categories: boot & kernel,
firmware & overlays, executables, libraries, configuration, systemd units,
logs, system data, user files, temporary files, scripts & tools. Also reports
setuid/setgid files, world-writable files, the 40 largest files, and files
modified in the last 7 days. Requires sudo; escalates automatically when
`SUDO_PASS` is set in the environment.

---

## Output Files

All output lands in `./output/` on the local machine (gitignored).
Filename format: `bbb_<scriptname>_<YYYYMMDD_HHMMSS>.txt`

Each report is plain text with `===` section headers, suitable for diffing
between runs or archiving.

---

## Adding a New Script

1. Create `bbb_<name>.sh` following the existing pattern:
   - Set `OUTFILE="/home/debian/bbb_<name>_$(date +%Y%m%d_%H%M%S).txt"`
   - Use `log()`, `section()`, and `run()` helpers
   - Print `$OUTFILE` as the final line of stdout
2. Add an entry to the `SCRIPTS` array in `bbb_master.sh`:
   ```bash
   "shortname|bbb_name.sh|no|Description of what it collects"
   ```
   Use `sudo` instead of `no` in field 3 if root is required.
3. Update the `--run` list in the usage comment block.
