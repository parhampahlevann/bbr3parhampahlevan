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

PRIMARY_INDEX=0
CURRENT=-1          # current active index (-1 = none)
PRIMARY_STABLE_ROUNDS=0

# Health-check parameters (tunable thresholds)
PING_COUNT=4                  # how many ping packets per check
PING_TIMEOUT=2                # seconds per ping
MAX_RTT_MS=150                # max acceptable RTT for "stable" primary
MAX_LOSS_PERCENT=10           # max acceptable packet loss for "stable" primary
HARD_DOWN_LOSS_PERCENT=80     # consider server "down" when loss >= this
PRIMARY_RECOVER_OK_ROUNDS=5   # primary must be stable this many loops to switch back
SWITCH_SCORE_MARGIN=50        # best server must beat current by this score
SLEEP_INTERVAL=1              # seconds between health checks

# Probe a server: prints "LOSS RTT"
probe_server() {
    local IP="$1"
    local OUT
    local LOSS=100
    local RTT=0

    OUT=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$IP" 2>/dev/null)
    local RC=$?

    if [[ $RC -ne 0 ]]; then
        LOSS=100
        RTT=0
    else
        LOSS=$(echo "$OUT" | awk -F',' '/packet loss/ {print $3}' | sed 's/[^0-9]//g')
        [[ -z "$LOSS" ]] && LOSS=100

        RTT=$(echo "$OUT" | awk -F'/' 'END{print $5}')
        [[ -z "$RTT" ]] && RTT=0
        RTT=${RTT%.*}
    fi

    echo "$LOSS $RTT"
}

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
    log "VXLAN is now using IRAN[ip=$REMOTE_IP]"
    return 0
}

monitor_loop() {
    log "Starting VXLAN failover monitor. IRAN IPs: ${IRAN_IPS[*]}"

    while true; do
        # Arrays to store current health
        declare -a LOSS_ARR=()
        declare -a RTT_ARR=()
        declare -a SCORE_ARR=()

        local i
        local best_index=-1
        local best_score=999999

        # Probe all IRAN servers
        for ((i=0; i<COUNT; i++)); do
            local IP="${IRAN_IPS[$i]}"
            read loss rtt < <(probe_server "$IP")

            LOSS_ARR[$i]=$loss
            RTT_ARR[$i]=$rtt

            # Simple health score: prioritize low loss + low latency
            local score=$(( loss * 10 + rtt ))
            SCORE_ARR[$i]=$score

            if (( loss < HARD_DOWN_LOSS_PERCENT )); then
                if (( score < best_score )); then
                    best_score=$score
                    best_index=$i
                fi
            fi

            log "Health: index=$i ip=$IP loss=${loss}% rtt=${rtt}ms score=$score"
        done

        # Primary server health
        local primary_loss=${LOSS_ARR[$PRIMARY_INDEX]:-100}
        local primary_rtt=${RTT_ARR[$PRIMARY_INDEX]:-0}
        local primary_score=${SCORE_ARR[$PRIMARY_INDEX]:-999999}

        # Track primary stability
        if (( primary_loss <= MAX_LOSS_PERCENT && primary_rtt <= MAX_RTT_MS )); then
            PRIMARY_STABLE_ROUNDS=$((PRIMARY_STABLE_ROUNDS + 1))
        else
            PRIMARY_STABLE_ROUNDS=0
        fi

        # Current server health
        local curr_loss=100
        local curr_rtt=0
        local curr_score=999999
        if (( CURRENT >= 0 )); then
            curr_loss=${LOSS_ARR[$CURRENT]:-100}
            curr_rtt=${RTT_ARR[$CURRENT]:-0}
            curr_score=${SCORE_ARR[$CURRENT]:-999999}
        fi

        log "Summary: current_index=$CURRENT curr_loss=${curr_loss}% curr_rtt=${curr_rtt}ms curr_score=$curr_score | primary_index=$PRIMARY_INDEX primary_loss=${primary_loss}% primary_rtt=${primary_rtt}ms primary_score=$primary_score stable_rounds=$PRIMARY_STABLE_ROUNDS"

        # Decision logic

        if (( best_index == -1 )); then
            log "No usable IRAN servers (all have very high loss). Keeping current if any."
        else
            if (( CURRENT == -1 )); then
                log "No active IRAN server. Switching to best index=$best_index."
                switch_to_index "$best_index"
            else
                # If current is effectively down, switch immediately
                if (( curr_loss >= HARD_DOWN_LOSS_PERCENT )); then
                    log "Current IRAN (${IRAN_IPS[$CURRENT]}) is effectively DOWN (loss=${curr_loss}%). Switching to best index=$best_index."
                    if (( best_index != CURRENT )); then
                        switch_to_index "$best_index"
                    fi
                else
                    # Current is at least partially usable
                    if (( best_index != CURRENT )); then
                        if (( best_index == PRIMARY_INDEX )); then
                            # Switch back to primary only if it's stable enough
                            if (( PRIMARY_STABLE_ROUNDS >= PRIMARY_RECOVER_OK_ROUNDS )); then
                                log "Primary is stable for $PRIMARY_STABLE_ROUNDS rounds, switching back to primary."
                                switch_to_index "$PRIMARY_INDEX"
                            else
                                log "Primary not stable enough yet (stable_rounds=$PRIMARY_STABLE_ROUNDS/$PRIMARY_RECOVER_OK_ROUNDS), staying on current."
                            fi
                        else
                            # Switch to a better backup if significantly healthier
                            if (( best_score + SWITCH_SCORE_MARGIN < curr_score )); then
                                log "Found much better backup IRAN index=$best_index (score=$best_score vs current=$curr_score). Switching."
                                switch_to_index "$best_index"
                            else
                                log "Current IRAN is still acceptable (score=$curr_score, best=$best_score). No switch."
                            fi
                        fi
                    else
                        log "Current IRAN server is already the best choice (index=$CURRENT, score=$curr_score)."
                    fi
                fi
            fi
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
