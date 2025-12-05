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

# Health-check parameters
PING_COUNT=1        # one ping
PING_TIMEOUT=5      # seconds per ping (≈ 5s failover)
SLEEP_INTERVAL=1    # between loops

CURRENT=-1          # current active index (-1 = none)

check_server() {
    local IP="$1"
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$IP" >/dev/null 2>&1
}

switch_to_index() {
    local INDEX="$1"
    local REMOTE_IP="${IRAN_IPS[$INDEX]}"

    log "Switching VXLAN to IRAN[index=$INDEX, ip=$REMOTE_IP]"

    ip link del "$VXLAN_IF" >/dev/null 2>&1 || true

    ip link add "$VXLAN_IF" type vxlan id "$VXLAN_ID" dev "$IFACE" remote "$REMOTE_IP" dstport 4789
    if [[ $? -ne 0 ]]; then
        log "ERROR: failed to create VXLAN interface to $REMOTE_IP"
        return 1
    fi

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

    CURRENT="$INDEX"
    log "VXLAN is now using IRAN[ip=$REMOTE_IP]"
    return 0
}

find_backup_index() {
    local i
    for ((i=0; i<COUNT; i++)); do
        if [[ "$i" -eq "$PRIMARY_INDEX" ]]; then
            continue
        fi
        if check_server "${IRAN_IPS[$i]}"; then
            echo "$i"
            return
        fi
    done
    echo "-1"
}

monitor_loop() {
    log "Starting VXLAN failover monitor. IRAN IPs: ${IRAN_IPS[*]}"

    while true; do
        # If primary is reachable → prefer it
        if check_server "${IRAN_IPS[$PRIMARY_INDEX]}"; then
            if [[ "$CURRENT" -ne "$PRIMARY_INDEX" ]]; then
                log "Primary IRAN is reachable, switching back to primary."
                switch_to_index "$PRIMARY_INDEX"
            fi
        else
            # Primary is down
            log "Primary IRAN (${IRAN_IPS[$PRIMARY_INDEX]}) is DOWN."

            if [[ "$CURRENT" -ge 0 && "$CURRENT" -ne "$PRIMARY_INDEX" ]]; then
                # We are on a backup; verify backup health
                if ! check_server "${IRAN_IPS[$CURRENT]}"; then
                    log "Current backup IRAN (${IRAN_IPS[$CURRENT]}) is also DOWN. Searching for another backup..."
                    local B
                    B=$(find_backup_index)
                    if [[ "$B" -ge 0 ]]; then
                        switch_to_index "$B"
                    else
                        log "No backup IRAN servers reachable."
                    fi
                fi
            else
                # We were on primary or nothing; try to find backup
                log "Trying to find a backup IRAN..."
                local B
                B=$(find_backup_index)
                if [[ "$B" -ge 0 ]]; then
                    switch_to_index "$B"
                else
                    log "No backup IRAN servers reachable."
                fi
            fi
        fi

        sleep "$SLEEP_INTERVAL"
    done
}

monitor_loop
EOF

    chmod +x /usr/local/bin/vxlan-failover.sh

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
