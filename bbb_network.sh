#!/usr/bin/env bash
# Detailed network state report for BeagleBone Black.
# Covers interfaces, capabilities, routing, ARP, DNS, TCP/UDP/Unix sockets,
# reverse-DNS session table, process-socket map, conntrack, and network logs.
# Requires root for full process visibility in ss/lsof.
# Output is written to /home/debian/bbb_network_<timestamp>.txt

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

OUTFILE="/home/debian/bbb_network_$(date +%Y%m%d_%H%M%S).txt"

log()     { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
section() { printf '\n==================================================\n%s\n==================================================\n' "$1" >> "$OUTFILE"; }
run()     { log "Running: $1"; section "$1"; eval "$2" >> "$OUTFILE" 2>&1 || true; log "Done:    $1"; }

# Reverse DNS lookup with timeout; returns hostname or the IP itself on failure.
rdns() {
    local ip="$1"
    host -W 2 "$ip" 2>/dev/null \
        | grep -oP '(?<=pointer ).*(?=\.)' \
        | head -1 \
        || printf '%s' "$ip"
}

log "Starting network report (running as $(whoami))"
log "Output file: $OUTFILE"

: > "$OUTFILE"
printf 'BBB Network Report\n'         >> "$OUTFILE"
printf 'Generated: %s\n' "$(date -Iseconds)" >> "$OUTFILE"
printf 'Hostname:  %s\n' "$(hostname)" >> "$OUTFILE"

# ── INTERFACE SUMMARY ────────────────────────────────────────────────────────
run "INTERFACE SUMMARY (ip addr)" "ip addr show"
run "INTERFACE LINK STATE"        "ip -s link show"

# ── PER-INTERFACE DEEP DIVE ──────────────────────────────────────────────────
log "Running: PER-INTERFACE DEEP DIVE"
section "PER-INTERFACE DEEP DIVE"

for sysdir in /sys/class/net/*/; do
    iface="$(basename "$sysdir")"
    [[ "$iface" == "lo" ]] && continue

    printf '\n--- %s ---\n' "$iface" >> "$OUTFILE"

    # Basic attributes from sysfs
    mac="$(cat "$sysdir/address"          2>/dev/null || echo 'n/a')"
    mtu="$(cat "$sysdir/mtu"              2>/dev/null || echo 'n/a')"
    state="$(cat "$sysdir/operstate"      2>/dev/null || echo 'n/a')"
    carrier="$(cat "$sysdir/carrier"      2>/dev/null || echo '0')"
    speed="$(cat "$sysdir/speed"          2>/dev/null || echo 'n/a')"
    duplex="$(cat "$sysdir/duplex"        2>/dev/null || echo 'n/a')"
    txqlen="$(cat "$sysdir/tx_queue_len"  2>/dev/null || echo 'n/a')"
    iface_type_id="$(cat "$sysdir/type"   2>/dev/null || echo '?')"

    # Decode ARPHRD type to human label
    case "$iface_type_id" in
        1)   iface_type="Ethernet" ;;
        772) iface_type="Loopback" ;;
        801) iface_type="WiFi (IEEE 802.11)" ;;
        512) iface_type="PPP" ;;
        280) iface_type="CAN" ;;
        803) iface_type="USB Network" ;;
        *)   iface_type="type-$iface_type_id" ;;
    esac

    # Driver info via symlink
    driver="$(basename "$(readlink -f "$sysdir/device/driver" 2>/dev/null)" 2>/dev/null || echo 'n/a')"

    # Check for VLAN support via kernel vlan module and /proc/net/vlan
    vlan_capable="unknown"
    if [[ -d /proc/net/vlan ]]; then
        vlan_capable="yes (vlan module loaded)"
    elif grep -q 8021q /proc/modules 2>/dev/null; then
        vlan_capable="yes (8021q module)"
    else
        vlan_capable="no vlan module detected"
    fi

    # Check for active VLAN sub-interfaces on this parent
    vlan_children="$(grep -l "VLAN_PLUS_VID_NO_PAD\|VID" /proc/net/vlan/* 2>/dev/null \
                     | xargs grep -l "$iface" 2>/dev/null \
                     | xargs basename 2>/dev/null | tr '\n' ' ' || echo 'none')"

    # Physical device bus info
    bus_info="$(cat "$sysdir/device/uevent" 2>/dev/null \
                | grep -E 'DRIVER|MODALIAS|DEVTYPE|OF_COMPATIBLE' | tr '\n' '  ' || echo 'n/a')"

    # IP addresses for this interface
    addrs="$(ip addr show dev "$iface" 2>/dev/null \
             | grep -E 'inet' | awk '{print $2, $3}' | tr '\n' '  ' || echo 'none')"

    {
        printf '  MAC:          %s\n'  "$mac"
        printf '  Type:         %s\n'  "$iface_type"
        printf '  Driver:       %s\n'  "$driver"
        printf '  State:        %s  (carrier: %s)\n' "$state" "$([[ "$carrier" == "1" ]] && echo up || echo down)"
        printf '  Speed:        %s Mbps\n' "$speed"
        printf '  Duplex:       %s\n'  "$duplex"
        printf '  MTU:          %s\n'  "$mtu"
        printf '  TX queue len: %s\n'  "$txqlen"
        printf '  IP addresses: %s\n'  "$addrs"
        printf '  VLAN support: %s\n'  "$vlan_capable"
        printf '  VLAN children:%s\n'  "$vlan_children"
        printf '  Bus/device:   %s\n'  "$bus_info"
    } >> "$OUTFILE"

    # RX/TX stats from /proc/net/dev
    stats="$(awk -v iface="${iface}:" '$1==iface {
        printf "  RX bytes=%-12s packets=%-10s errors=%-6s dropped=%s\n",$2,$3,$4,$5
        printf "  TX bytes=%-12s packets=%-10s errors=%-6s dropped=%s\n",$10,$11,$12,$13
    }' /proc/net/dev)"
    printf '%s\n' "$stats" >> "$OUTFILE"

done
log "Done:    PER-INTERFACE DEEP DIVE"

# ── ROUTING ──────────────────────────────────────────────────────────────────
run "ROUTING TABLE (IPv4)"  "ip route show"
run "ROUTING TABLE (IPv6)"  "ip -6 route show"
run "FIB TRIE SUMMARY"      "head -30 /proc/net/fib_trie 2>/dev/null || echo 'not available'"

# ── ARP / NEIGHBORS ──────────────────────────────────────────────────────────
run "ARP / NEIGHBOR TABLE"  "ip neigh show"
run "ARP TABLE (/proc)"     "cat /proc/net/arp"

# ── DNS CONFIGURATION ────────────────────────────────────────────────────────
run "RESOLV.CONF"           "cat /etc/resolv.conf 2>/dev/null || echo 'not found'"
run "HOSTS FILE"            "cat /etc/hosts"
run "NSSWITCH.CONF"         "cat /etc/nsswitch.conf 2>/dev/null || echo 'not found'"
run "DNS LOOKUP TEST (hostname)" "host \"$(hostname)\" 2>/dev/null || getent hosts \"$(hostname)\" || echo 'lookup failed'"

# ── LISTENING SOCKETS ────────────────────────────────────────────────────────
log "Running: LISTENING SOCKETS (TCP + UDP)"
section "LISTENING SOCKETS (TCP + UDP)"
{
    printf '%-6s %-6s %-40s %-8s %-30s %s\n' \
        "Proto" "State" "Local Address" "PID" "Process" "Executable"
    printf '%s\n' "$(printf '─%.0s' {1..110})"

    ss -tlnp 2>/dev/null | awk 'NR>1' | while IFS= read -r line; do
        proto="TCP"
        state=$(printf '%s' "$line" | awk '{print $1}')
        local=$(printf '%s' "$line" | awk '{print $4}')
        proc_field=$(printf '%s' "$line" | grep -oP 'users:\(.*?\)' || echo '')
        pid=$(printf '%s' "$proc_field" | grep -oP 'pid=\K[0-9]+' | head -1 || echo '')
        pname=$(printf '%s' "$proc_field" | grep -oP '"\K[^"]+' | head -1 || echo '-')
        exe=$([ -n "$pid" ] && readlink "/proc/$pid/exe" 2>/dev/null || echo '-')
        printf '%-6s %-6s %-40s %-8s %-30s %s\n' "$proto" "$state" "$local" "$pid" "$pname" "$exe"
    done

    ss -ulnp 2>/dev/null | awk 'NR>1' | while IFS= read -r line; do
        proto="UDP"
        local=$(printf '%s' "$line" | awk '{print $4}')
        proc_field=$(printf '%s' "$line" | grep -oP 'users:\(.*?\)' || echo '')
        pid=$(printf '%s' "$proc_field" | grep -oP 'pid=\K[0-9]+' | head -1 || echo '')
        pname=$(printf '%s' "$proc_field" | grep -oP '"\K[^"]+' | head -1 || echo '-')
        exe=$([ -n "$pid" ] && readlink "/proc/$pid/exe" 2>/dev/null || echo '-')
        printf '%-6s %-6s %-40s %-8s %-30s %s\n' "$proto" "n/a" "$local" "$pid" "$pname" "$exe"
    done
} >> "$OUTFILE"
log "Done:    LISTENING SOCKETS (TCP + UDP)"

# ── TCP SESSION TABLE WITH REVERSE DNS ───────────────────────────────────────
log "Running: TCP SESSION TABLE WITH REVERSE DNS"
section "TCP SESSION TABLE WITH REVERSE DNS"
{
    printf '%-12s %-25s %-25s %-35s %s\n' \
        "State" "Local" "Remote" "Remote Hostname" "Process"
    printf '%s\n' "$(printf '─%.0s' {1..120})"

    # Build a temp associative-style cache file for DNS results
    dns_cache="$(mktemp)"

    ss -tnap 2>/dev/null | awk 'NR>1' | while IFS= read -r line; do
        state=$(printf '%s' "$line" | awk '{print $1}')
        local=$(printf '%s' "$line" | awk '{print $4}')
        remote=$(printf '%s' "$line" | awk '{print $5}')
        proc_field=$(printf '%s' "$line" | grep -oP 'users:\(.*?\)' || echo '')
        pname=$(printf '%s' "$proc_field" | grep -oP '"\K[^"]+' | head -1 || echo '-')

        # Extract remote IP (handle IPv4 and [::]:port forms)
        remote_ip=$(printf '%s' "$remote" | sed 's/\[//g;s/\]//g' | rev | cut -d: -f2- | rev)

        if [[ -z "$remote_ip" || "$remote_ip" == "*" || "$remote_ip" == "0.0.0.0" ]]; then
            hostname="-"
        else
            # Check cache
            cached=$(grep -F "${remote_ip}=" "$dns_cache" 2>/dev/null | cut -d= -f2 || true)
            if [[ -n "$cached" ]]; then
                hostname="$cached"
            else
                hostname=$(rdns "$remote_ip")
                printf '%s=%s\n' "$remote_ip" "$hostname" >> "$dns_cache"
            fi
        fi

        printf '%-12s %-25s %-25s %-35s %s\n' \
            "$state" "$local" "$remote" "$hostname" "$pname"
    done

    rm -f "$dns_cache"
} >> "$OUTFILE"
log "Done:    TCP SESSION TABLE WITH REVERSE DNS"

# ── UDP SOCKETS ───────────────────────────────────────────────────────────────
run "UDP SOCKETS (all)"   "ss -unap"

# ── UNIX DOMAIN SOCKETS ──────────────────────────────────────────────────────
run "UNIX SOCKETS (listening)" "ss -xlnp"

# ── PROCESS → SOCKET MAP ─────────────────────────────────────────────────────
log "Running: PROCESS-SOCKET MAP"
section "PROCESS-SOCKET MAP"
{
    printf 'All network file descriptors grouped by process.\n\n'

    # lsof -i gives all internet sockets; -U adds unix sockets
    lsof -i -n -P 2>/dev/null | awk 'NR==1 || NF>0' | sort -k1,1 -k2,2n > /tmp/_bbb_lsof_net.txt || true

    # Get unique PIDs from lsof output
    pids=$(awk 'NR>1 {print $2}' /tmp/_bbb_lsof_net.txt 2>/dev/null | sort -un || true)

    for pid in $pids; do
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || echo 'unknown')
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 120 || echo 'unknown')
        user=$(awk 'NR==1{print $3}' /tmp/_bbb_lsof_net.txt 2>/dev/null || echo '?')

        printf '\nPID: %s  EXE: %s\n' "$pid" "$exe"      >> "$OUTFILE"
        printf 'CMD: %s\n' "$cmdline"                     >> "$OUTFILE"

        # Network sockets for this PID
        printf 'Network sockets:\n'                       >> "$OUTFILE"
        awk -v p="$pid" '$2==p' /tmp/_bbb_lsof_net.txt \
            | awk '{printf "  %-6s %-6s %-10s %-12s %s\n", $5,$8,$9,$10,$NF}' >> "$OUTFILE" || true

        # Supporting files: non-socket, non-pipe open FDs
        printf 'Supporting files (open non-socket FDs):\n' >> "$OUTFILE"
        lsof -p "$pid" -n -P 2>/dev/null \
            | awk '$5!~/sock|IPv|REG|DIR|CHR/ || $7~/\.conf|\.so|\.cfg|\.json|\.ini/ {
                     if($1!="COMMAND" && $9!~/^socket|^pipe/) print "  "$9
                  }' \
            | sort -u | head -20 >> "$OUTFILE" || true

        # Shared libraries from maps
        printf 'Loaded shared libraries:\n'               >> "$OUTFILE"
        grep '\.so' "/proc/$pid/maps" 2>/dev/null \
            | awk '{print $NF}' | sort -u \
            | sed 's/^/  /'                                >> "$OUTFILE" || true
    done

    rm -f /tmp/_bbb_lsof_net.txt
} >> "$OUTFILE"
log "Done:    PROCESS-SOCKET MAP"

# ── NETFILTER / CONNTRACK ────────────────────────────────────────────────────
run "CONNECTION TRACKING (nf_conntrack)" \
    "cat /proc/net/nf_conntrack 2>/dev/null || echo 'conntrack not available or empty'"
run "CONNTRACK STATS" \
    "cat /proc/net/nf_conntrack_expect 2>/dev/null | head -20 || echo 'not available'"
run "NETFILTER TABLES"  "cat /proc/net/ip_tables_names 2>/dev/null || echo 'none'"

# ── SOCKET STATISTICS ────────────────────────────────────────────────────────
run "SOCKET STATS (/proc/net/sockstat)"  "cat /proc/net/sockstat"
run "SOCKET STATS IPv6"                  "cat /proc/net/sockstat6 2>/dev/null || echo 'not available'"
run "PROTOCOL STATS (/proc/net/snmp)"    "cat /proc/net/snmp"
run "NETSTAT SUMMARY"                    "netstat -s 2>/dev/null | head -60 || echo 'not available'"

# ── INTERFACE STATISTICS ─────────────────────────────────────────────────────
run "INTERFACE STATS (/proc/net/dev)"    "cat /proc/net/dev"
run "WIRELESS INFO (/proc/net/wireless)" "cat /proc/net/wireless 2>/dev/null || echo 'no wireless interfaces'"

# ── VLAN ─────────────────────────────────────────────────────────────────────
run "VLAN INTERFACES" \
    "ls /proc/net/vlan/ 2>/dev/null && cat /proc/net/vlan/config 2>/dev/null || echo 'no VLAN interfaces configured'"

# ── CAN NETWORK ──────────────────────────────────────────────────────────────
run "CAN NETWORK INTERFACES" \
    "ip -details link show type can 2>/dev/null || echo 'no CAN interfaces'"
run "CAN STATISTICS" \
    "cat /proc/net/can 2>/dev/null || echo 'not available'"

# ── NETWORK LOGS ─────────────────────────────────────────────────────────────
run "DMESG (network events)" \
    "dmesg 2>/dev/null | grep -iE 'eth|net|link|dhcp|tcp|arp|ip |cpsw|phy|carrier|usb.*net|rndis' | tail -60 || echo 'none'"
run "SYSLOG (network events, last 100 lines)" \
    "grep -iE 'dhcp|eth|network|resolv|dns|interface|link|ip addr|arp' /var/log/syslog 2>/dev/null | tail -100 || echo 'syslog not available'"
run "DAEMON LOG (networking)" \
    "grep -iE 'dhcp|network|eth|link' /var/log/daemon.log 2>/dev/null | tail -50 || echo 'not available'"

log "Collection complete. Report written to: $OUTFILE"
printf '%s\n' "$OUTFILE"
