#!/bin/bash

# ==============================
# VXLAN Multi-IP Failover Script
# ==============================

VXLAN_IF="vxlan100"
VXLAN_ID=100

# Local VXLAN IPs
VXLAN_IPV4_KHAREJ="10.123.1.2/30"
VXLAN_IPV4_IRAN="10.123.1.1/30"
VXLAN_IPV6_KHAREJ="fd11:1ceb:1d11::2/64"
VXLAN_IPV6_IRAN="fd11:1ceb:1d11::1/64"

CONF_FILE="/etc/vxlan-failover.conf"
LOG_FILE="/var/log/vxlan-failover.log"

get_iface() {
    ip route | awk '/default/ {print $5; exit}'
}

# ------------------------------
# IRAN SERVER SETUP
# ------------------------------
setup_iran() {
    echo "=== IRAN SERVER VXLAN SETUP ==="
    read -p "Enter KHAREJ server IP: " REMOTE_IP

    IFACE=$(get_iface)
    echo "Detected default interface: $IFACE"

    # Clean previous VXLAN if exists
    ip link del "$VXLAN_IF" >/dev/null 2>&1 || true

    # Configure VXLAN
    ip link add "$VXLAN_IF" type vxlan id "$VXLAN_ID" dev "$IFACE" remote "$REMOTE_IP" dstport 4789
    ip addr add "$VXLAN_IPV4_IRAN" dev "$VXLAN_IF"
    ip -6 addr add "$VXLAN_IPV6_IRAN" dev "$VXLAN_IF"
    ip link set "$VXLAN_IF" up

cat <<EOF > /etc/rc.local
#!/bin/bash
IFACE="$IFACE"
VXLAN_IF="$VXLAN_IF"
VXLAN_ID="$VXLAN_ID"
REMOTE_IP="$REMOTE_IP"

ip link del "\$VXLAN_IF" >/dev/null 2>&1 || true
ip link add "\$VXLAN_IF" type vxlan id "\$VXLAN_ID" dev "\$IFACE" remote "\$REMOTE_IP" dstport 4789
ip addr add "$VXLAN_IPV4_IRAN" dev "\$VXLAN_IF"
ip -6 addr add "$VXLAN_IPV6_IRAN" dev "\$VXLAN_IF"
ip link set "\$VXLAN_IF" up

exit 0
EOF

    chmod +x /etc/rc.local
    systemctl enable rc-local >/dev/null 2>&1 || systemctl enable rc-local.service >/dev/null 2>&1
    systemctl start rc-local >/dev/null 2>&1 || systemctl start rc-local.service >/dev/null 2>&1

    echo "IRAN VXLAN setup complete."
    echo "Local VXLAN IP: $VXLAN_IPV4_IRAN"
}

# ------------------------------
# KHAREJ SERVER (MULTI-IP FAILOVER)
# ------------------------------
setup_kharej() {
    echo "=== KHAREJ SERVER MULTI-IRAN FAILOVER SETUP ==="

    while true; do
        read -p "How many IRAN servers? (1-3): " COUNT
        [[ "$COUNT" =~ ^[1-3]$ ]] && break
        echo "Invalid number. Enter 1, 2, or 3."
    done

    IRAN_IPS=()
    for ((i=1; i<=COUNT; i++)); do
        read -p "Enter PUBLIC IP of IRAN server #$i (priority #$i): " IP
        IRAN_IPS+=("$IP")
    done

    IFACE=$(get_iface)
    echo "Detected default interface: $IFACE"

    # Clean previous VXLAN if exists
    ip link del "$VXLAN_IF" >/dev/null 2>&1 || true

    IRAN_IPS_STR="${IRAN_IPS[*]}"

    # Save config for both failover + status
cat <<EOF > "$CONF_FILE"
IFACE="$IFACE"
VXLAN_IF="$VXLAN_IF"
VXLAN_ID="$VXLAN_ID"
IRAN_IPS=($IRAN_IPS_STR)
COUNT=$COUNT
VXLAN_IPV4_KHAREJ="$VXLAN_IPV4_KHAREJ"
VXLAN_IPV6_KHAREJ="$VXLAN_IPV6_KHAREJ"
EOF

    # Create failover script
cat <<'EOF' > /usr/local/bin/vxlan-failover.sh
#!/bin/bash

CONF_FILE="/etc/vxlan-failover.conf"
LOG_FILE="/var/log/vxlan-failover.log"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

log() {
    echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"
}

if [[ ! -f "$CONF_FILE" ]]; then
    log "ERROR: Config file $CONF_FILE not found. Exiting."
    exit 1
fi

# Load config
# shellcheck disable=SC1090
source "$CONF_FILE"

PRIMARY_INDEX=0         # just for info / possible future preference
CURRENT=-1              # current active index (-1 = none)
CURRENT_BAD_STREAK=0    # how many consecutive bad checks on current

# Quick health thresholds
QUICK_WARN_LOSS=30      # % packet loss to start worrying
QUICK_WARN_RTT=200      # ms RTT to start worrying
QUICK_HARD_LOSS=80      # % loss = effectively down
BAD_STREAK_LIMIT=3      # how many bad quick checks before 30s test

# Long test parameters
LONG_TEST_DURATION=30   # seconds to run continuous pings when evaluating
MAX_LOSS_FOR_CANDIDATE=95   # ignore servers with loss >= this in long test

SLEEP_INTERVAL=1        # seconds between quick checks

# ------------------------------
# Helpers: probing
# ------------------------------

# Quick probe: 1 ping, returns "LOSS RTT"
quick_probe_server() {
    local IP="$1"
    local OUT
    local LOSS=100
    local RTT=0

    OUT=$(ping -c1 -W1 "$IP" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        LOSS=100
        RTT=0
    else
        LOSS=0
        RTT=$(echo "$OUT" | awk -F'/' 'END{print $5}')
        RTT=${RTT%.*}
        [[ -z "$RTT" ]] && RTT=0
    fi

    echo "$LOSS $RTT"
}

# Long probe: ~30 seconds, 1 ping per second
# returns: "LOSS RTT_AVG"
long_probe_server() {
    local IP="$1"
    local DURATION="$LONG_TEST_DURATION"

    local start=$SECONDS
    local sent=0
    local recv=0
    local rtt_sum=0

    while (( SECONDS - start < DURATION )); do
        local OUT
        OUT=$(ping -c1 -W1 "$IP" 2>/dev/null)
        ((sent++))

        if [[ $? -eq 0 ]]; then
            local rtt
            rtt=$(echo "$OUT" | awk -F'/' 'END{print $5}')
            rtt=${rtt%.*}
            [[ -z "$rtt" ]] && rtt=0
            rtt_sum=$((rtt_sum + rtt))
            ((recv++))
        fi

        sleep 1
    done

    local loss=100
    local avg_rtt=0

    if (( sent > 0 )); then
        loss=$(( (sent - recv) * 100 / sent ))
    fi

    if (( recv > 0 )); then
        avg_rtt=$(( rtt_sum / recv ))
    else
        avg_rtt=9999
    fi

    echo "$loss $avg_rtt"
}

# Choose the best server using 30s tests for ALL candidates
choose_best_server_long() {
    local i
    local best_index=-1
    local best_score=999999

    log "Starting 30-second evaluation for all IRAN servers..."

    for ((i=0; i<COUNT; i++)); do
        local IP="${IRAN_IPS[$i]}"
        local loss rtt

        read loss rtt < <(long_probe_server "$IP")
        local score=$(( loss * 100 + rtt ))

        log "30s result: index=$i ip=$IP loss=${loss}% rtt=${rtt}ms score=$score"

        # Ignore very bad candidates
        if (( loss >= MAX_LOSS_FOR_CANDIDATE )); then
            continue
        fi

        if (( score < best_score )); then
            best_score=$score
            best_index=$i
        fi
    done

    log "30s evaluation best_index=$best_index best_score=$best_score"
    echo "$best_index"
}

# ------------------------------
# Switch VXLAN to given index
# ------------------------------
switch_to_index() {
    local INDEX="$1"
    local REMOTE_IP="${IRAN_IPS[$INDEX]}"

    log "Switching VXLAN to IRAN[index=$INDEX, ip=$REMOTE_IP]"

    # Backup current routes on VXLAN interface (if any)
    local ROUTES=""
    if ip link show "$VXLAN_IF" >/dev/null 2>&1; then
        ROUTES=$(ip route show dev "$VXLAN_IF" 2>/dev/null || true)
    fi

    # Remove old interface
    ip link set "$VXLAN_IF" down >/dev/null 2>&1 || true
    ip link del "$VXLAN_IF" >/dev/null 2>&1 || true

    # Create new VXLAN interface pointing to new IRAN endpoint
    ip link add "$VXLAN_IF" type vxlan id "$VXLAN_ID" dev "$IFACE" remote "$REMOTE_IP" dstport 4789
    if [[ $? -ne 0 ]]; then
        log "ERROR: failed to create VXLAN interface to $REMOTE_IP"
        return 1
    fi

    # Assign IP addresses
    ip addr flush dev "$VXLAN_IF" || true

    ip addr add "$VXLAN_IPV4_KHAREJ" dev "$VXLAN_IF" || {
        log "ERROR: failed to set IPv4 address on $VXLAN_IF"
        return 1
    }

    ip -6 addr add "$VXLAN_IPV6_KHAREJ" dev "$VXLAN_IF" >/dev/null 2>&1 || true

    ip link set "$VXLAN_IF" up || {
        log "ERROR: failed to set $VXLAN_IF up"
        return 1
    }

    # Restore routes that were previously on this interface
    if [[ -n "$ROUTES" ]]; then
        log "Restoring routes on $VXLAN_IF:"
        while IFS= read -r R; do
            [[ -z "$R" ]] && continue
            log "  ip route add $R"
            ip route add $R 2>/dev/null || log "WARN: failed to restore route: $R"
        done <<< "$ROUTES"
    fi

    # Flush ARP and FDB to avoid stale MAC/neighbor entries
    ip neigh flush dev "$VXLAN_IF" 2>/dev/null || true
    bridge fdb flush dev "$VXLAN_IF" 2>/dev/null || true

    CURRENT="$INDEX"
    CURRENT_BAD_STREAK=0
    log "VXLAN is now using IRAN[ip=$REMOTE_IP]"
    return 0
}

# ------------------------------
# Main monitor loop
# ------------------------------
monitor_loop() {
    log "Starting VXLAN failover monitor. IRAN IPs: ${IRAN_IPS[*]}"

    while true; do
        # If we don't have an active server yet → run full 30s evaluation
        if (( CURRENT == -1 )); then
            log "No active IRAN server yet. Running 30s evaluation to choose the best."
            local best
            best=$(choose_best_server_long)
            if (( best >= 0 )); then
                switch_to_index "$best"
            else
                log "No suitable IRAN server found in 30s evaluation. Retrying later."
            fi
            sleep "$SLEEP_INTERVAL"
            continue
        fi

        # We have a current server → quick check on it
        local curr_ip="${IRAN_IPS[$CURRENT]}"
        local loss rtt
        read loss rtt < <(quick_probe_server "$curr_ip")

        log "Quick health current_index=$CURRENT ip=$curr_ip loss=${loss}% rtt=${rtt}ms bad_streak=$CURRENT_BAD_STREAK"

        # If effectively down → immediate 30s eval
        if (( loss >= QUICK_HARD_LOSS )); then
            log "Current IRAN looks DOWN or very bad (loss=${loss}%). Running 30s evaluation for all servers."
            local best
            best=$(choose_best_server_long)
            if (( best >= 0 && best != CURRENT )); then
                switch_to_index "$best"
            else
                log "30s evaluation did not find a better server than current. Keeping current."
            fi
            CURRENT_BAD_STREAK=0
            sleep "$SLEEP_INTERVAL"
            continue
        fi

        # Degraded but not fully down? count bad streak
        if (( loss > QUICK_WARN_LOSS || rtt > QUICK_WARN_RTT )); then
            CURRENT_BAD_STREAK=$((CURRENT_BAD_STREAK + 1))
            log "Current IRAN degraded (loss=${loss}%, rtt=${rtt}ms). bad_streak=$CURRENT_BAD_STREAK"

            if (( CURRENT_BAD_STREAK >= BAD_STREAK_LIMIT )); then
                log "Current IRAN degraded for ${BAD_STREAK_LIMIT} consecutive checks. Running 30s evaluation for all servers."
                local best
                best=$(choose_best_server_long)
                if (( best >= 0 && best != CURRENT )); then
                    switch_to_index "$best"
                else
                    log "30s evaluation did not find a better server than current. Keeping current."
                fi
                CURRENT_BAD_STREAK=0
            fi
        else
            # Healthy again → reset streak
            CURRENT_BAD_STREAK=0
        fi

        sleep "$SLEEP_INTERVAL"
    done
}

monitor_loop
EOF

    chmod +x /usr/local/bin/vxlan-failover.sh

    # Kill any existing failover monitor to avoid duplicates
    pkill -f /usr/local/bin/vxlan-failover.sh 2>/dev/null || true

    # Start failover script now (background)
    /usr/local/bin/vxlan-failover.sh &

    # Ensure it runs on boot via rc.local
cat <<EOF > /etc/rc.local
#!/bin/bash
/usr/local/bin/vxlan-failover.sh &
exit 0
EOF

    chmod +x /etc/rc.local
    systemctl enable rc-local >/dev/null 2>&1 || systemctl enable rc-local.service >/dev/null 2>&1
    systemctl start rc-local >/dev/null 2>&1 || systemctl start rc-local.service >/dev/null 2>&1

    echo "KHAREJ VXLAN failover setup complete."
    echo "IRAN servers (priority order): ${IRAN_IPS_STR}"
    echo "Failover log: $LOG_FILE"
}

# ------------------------------
# STATUS / LIVE MONITOR
# ------------------------------
status_vxlan() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "VXLAN failover is not configured on this server."
        return
    fi

    # shellcheck disable=SC1090
    source "$CONF_FILE"

    echo "Press Ctrl+C to exit status monitor."
    sleep 1

    while true; do
        clear
        echo "==========================="
        echo " VXLAN Status / Live Monitor"
        echo "==========================="
        echo

        if ip link show "$VXLAN_IF" >/dev/null 2>&1; then
            ACTIVE_REMOTE=$(ip -d link show "$VXLAN_IF" 2>/dev/null | \
                awk '/remote/ {for (i=1;i<=NF;i++) if ($i=="remote") print $(i+1)}' | head -n1)
            echo "Interface: $VXLAN_IF (PRESENT)"
            echo "Current remote (IRAN in use): ${ACTIVE_REMOTE:-UNKNOWN}"
        else
            ACTIVE_REMOTE=""
            echo "Interface: $VXLAN_IF (NOT PRESENT)"
        fi

        echo
        echo "IRAN servers health (ping from KHAREJ):"
        echo "---------------------------------------"

        idx=0
        for ip in "${IRAN_IPS[@]}"; do
            if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
                state="UP"
            else
                state="DOWN"
            fi

            marker=""
            if [[ -n "$ACTIVE_REMOTE" && "$ip" == "$ACTIVE_REMOTE" ]]; then
                marker="<-- ACTIVE"
            fi

            echo "[$idx] $ip : $state $marker"
            idx=$((idx+1))
        done

        echo
        echo "Last 5 log lines:"
        echo "-----------------"
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 5 "$LOG_FILE"
        else
            echo "No log file found: $LOG_FILE"
        fi

        sleep 1
    done
}

# ------------------------------
# FULL UNINSTALL (DELETE EVERYTHING)
# ------------------------------
uninstall_vxlan() {
    echo "=== Removing VXLAN Completely ==="

    systemctl disable rc-local >/dev/null 2>&1 || true
    systemctl stop rc-local >/dev/null 2>&1 || true

    rm -f /etc/rc.local
    rm -f /usr/local/bin/vxlan-failover.sh
    rm -f "$CONF_FILE"
    rm -f "$LOG_FILE"

    ip link del "$VXLAN_IF" >/dev/null 2>&1 || true

    echo "All VXLAN configurations removed."
}

# ------------------------------
# MENU
# ------------------------------
main_menu() {
    clear
    echo "==============================="
    echo " VXLAN Multi-IP Tunnel Manager "
    echo "==============================="
    echo "1) Setup IRAN Server"
    echo "2) Setup KHAREJ Server (Failover)"
    echo "3) Uninstall VXLAN Completely"
    echo "4) Reboot Server"
    echo "5) Show Status / Live Monitor"
    echo "6) Exit"
    echo "-------------------------------"

    read -p "Choose option (1-6): " CHOICE

    case "$CHOICE" in
        1) setup_iran ;;
        2) setup_kharej ;;
        3) uninstall_vxlan ;;
        4) reboot ;;
        5) status_vxlan ;;
        6) exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
}

main_menu
