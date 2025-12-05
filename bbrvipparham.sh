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
    ip link del $VXLAN_IF >/dev/null 2>&1 || true

    # Configure VXLAN
    ip link add $VXLAN_IF type vxlan id $VXLAN_ID dev $IFACE remote $REMOTE_IP dstport 4789
    ip addr add $VXLAN_IPV4_IRAN dev $VXLAN_IF
    ip -6 addr add $VXLAN_IPV6_IRAN dev $VXLAN_IF
    ip link set $VXLAN_IF up

cat <<EOF > /etc/rc.local
#!/bin/bash
IFACE="$IFACE"
VXLAN_IF="$VXLAN_IF"
VXLAN_ID="$VXLAN_ID"
REMOTE_IP="$REMOTE_IP"

ip link del \$VXLAN_IF >/dev/null 2>&1 || true
ip link add \$VXLAN_IF type vxlan id \$VXLAN_ID dev \$IFACE remote \$REMOTE_IP dstport 4789
ip addr add $VXLAN_IPV4_IRAN dev \$VXLAN_IF
ip -6 addr add $VXLAN_IPV6_IRAN dev \$VXLAN_IF
ip link set \$VXLAN_IF up

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
    ip link del $VXLAN_IF >/dev/null 2>&1 || true

    IRAN_IPS_STR="${IRAN_IPS[*]}"

    # Create failover script
cat <<EOF > /usr/local/bin/vxlan-failover.sh
#!/bin/bash

# Injected constants
IFACE="$IFACE"
VXLAN_IF="$VXLAN_IF"
VXLAN_ID="$VXLAN_ID"
IRAN_IPS=($IRAN_IPS_STR)
COUNT=$COUNT

VXLAN_IPV4_KHAREJ="$VXLAN_IPV4_KHAREJ"
VXLAN_IPV6_KHAREJ="$VXLAN_IPV6_KHAREJ"

# Health-check settings
PING_COUNT=1        # 1 ping per server
PING_TIMEOUT=5      # timeout per ping (seconds) -> max ~5s until failover
SLEEP_INTERVAL=1    # main loop sleep (seconds)

CURRENT=-1          # current active IRAN index (-1 = none yet)

check_server() {
    local IP="\$1"
    ping -c "\$PING_COUNT" -W "\$PING_TIMEOUT" "\$IP" >/dev/null 2>&1
}

select_best_server() {
    local i
    for ((i=0; i<COUNT; i++)); do
        if check_server "\${IRAN_IPS[\$i]}"; then
            echo "\$i"
            return
        fi
    done
    echo "-1"
}

create_vxlan() {
    local INDEX="\$1"
    local REMOTE_IP="\${IRAN_IPS[\$INDEX]}"

    echo ">>> Creating VXLAN to IRAN server [index=\$INDEX, ip=\$REMOTE_IP]"

    ip link del "\$VXLAN_IF" >/dev/null 2>&1 || true

    ip link add "\$VXLAN_IF" type vxlan id "\$VXLAN_ID" dev "\$IFACE" remote "\$REMOTE_IP" dstport 4789

    ip addr flush dev "\$VXLAN_IF"
    ip addr add "\$VXLAN_IPV4_KHAREJ" dev "\$VXLAN_IF"
    ip -6 addr add "\$VXLAN_IPV6_KHAREJ" dev "\$VXLAN_IF"
    ip link set "\$VXLAN_IF" up
}

monitor_loop() {
    echo ">>> Starting VXLAN failover monitor..."
    while true; do
        local BEST
        BEST=\$(select_best_server)

        if [[ "\$BEST" -lt 0 ]]; then
            echo "!!! No IRAN servers reachable. Keeping current state (if any)."
        else
            if [[ "\$BEST" -ne "\$CURRENT" ]]; then
                echo "Active IRAN server should be index=\$BEST (IP=\${IRAN_IPS[\$BEST]}). Switching..."
                CURRENT="\$BEST"
                create_vxlan "\$CURRENT"
            fi
        fi

        sleep "\$SLEEP_INTERVAL"
    done
}

monitor_loop
EOF

    chmod +x /usr/local/bin/vxlan-failover.sh

    # Start failover script now
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

    ip link del $VXLAN_IF >/dev/null 2>&1 || true

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
    echo "5) Exit"
    echo "-------------------------------"

    read -p "Choose option (1-5): " CHOICE

    case "$CHOICE" in
        1) setup_iran ;;
        2) setup_kharej ;;
        3) uninstall_vxlan ;;
        4) reboot ;;
        5) exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
}

main_menu
