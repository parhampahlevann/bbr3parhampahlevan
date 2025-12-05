#!/bin/bash

# ==============================
# VXLAN Multi-IP Failover Script
# Compatible with: Ubuntu / Debian
# Author: Parham (modified)
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
# KHAREJ SERVER (MULTI-IP FAILOVER WITH PRIMARY PREFERENCE)
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

    # Clean previous VXLAN
    ip link del $VXLAN_IF >/dev/null 2>&1 || true

    IRAN_IPS_STR="${IRAN_IPS[*]}"

# Create failover script
cat <<EOF > /usr/local/bin/vxlan-failover.sh
#!/bin/bash

IFACE="$IFACE"
VXLAN_IF="$VXLAN_IF"
VXLAN_ID="$VXLAN_ID"
IRAN_IPS=($IRAN_IPS_STR)
COUNT=\${#IRAN_IPS[@]}
CURRENT=-1   # -1 = none active yet

VXLAN_IPV4_KHAREJ="$VXLAN_IPV4_KHAREJ"
VXLAN_IPV6_KHAREJ="$VXLAN_IPV6_KHAREJ"

# Health-check parameters
PING_COUNT=2          # 2 pings
PING_TIMEOUT=5        # each ping up to 5 seconds -> ~10 seconds total per server

create_vxlan() {
    local INDEX="\$1"
    local REMOTE_IP="\${IRAN_IPS[\$INDEX]}"

    echo ">>> Switching VXLAN remote to IRAN server [index=\$INDEX, ip=\$REMOTE_IP]"

    ip link del "\$VXLAN_IF" >/dev/null 2>&1 || true

    ip link add "\$VXLAN_IF" type vxlan id "\$VXLAN_ID" dev "\$IFACE" remote "\$REMOTE_IP" dstport 4789

    ip addr flush dev "\$VXLAN_IF"
    ip addr add "\$VXLAN_IPV4_KHAREJ" dev "\$VXLAN_IF"
    ip -6 addr add "\$VXLAN_IPV6_KHAREJ" dev "\$VXLAN_IF"
    ip link set "\$VXLAN_IF" up
}

check_server() {
    local IP="\$1"
    ping -c "\$PING_COUNT" -W "\$PING_TIMEOUT" "\$IP" >/dev/null 2>&1
}

monitor_loop() {
    while true; do
        local preferred_index=-1

        # Always prefer the first reachable server in the list
        local i
        for ((i=0; i<COUNT; i++)); do
            local ip="\${IRAN_IPS[\$i]}"
            if check_server "\$ip"; then
                preferred_index=\$i
                break
            fi
        done

        if [[ "\$preferred_index" -eq -1 ]]; then
            echo "!!! No IRAN servers are reachable. Keeping current VXLAN (if any)."
        else
            # If the best available server is not the current, switch
            if [[ "\$preferred_index" -ne "\$CURRENT" ]]; then
                echo "Health-check: best available IRAN server is index=\$preferred_index (IP=\${IRAN_IPS[\$preferred_index]})."
                CURRENT=\$preferred_index
                create_vxlan "\$CURRENT"
            fi
        fi

        sleep 2
    done
}

monitor_loop
EOF

    chmod +x /usr/local/bin/vxlan-failover.sh

    # Start now
    /usr/local/bin/vxlan-failover.sh &

# rc.local auto-run on boot
cat <<EOF > /etc/rc.local
#!/bin/bash
/usr/local/bin/vxlan-failover.sh &
exit 0
EOF

    chmod +x /etc/rc.local
    systemctl enable rc-local >/dev/null 2>&1 || systemctl enable rc-local.service >/dev/null 2>&1
    systemctl start rc-local >/dev/null 2>&1 || systemctl start rc-local.service >/dev/null 2>&1

    echo "KHAREJ VXLAN failover setup complete."
    echo "IRAN servers configured (priority order): ${IRAN_IPS_STR}"
}

# ------------------------------
# MENU
# ------------------------------
main_menu() {
    echo "==============================="
    echo " VXLAN Multi-IP Tunnel Manager "
    echo "==============================="
    echo "1) Setup IRAN Server"
    echo "2) Setup KHAREJ Server (Failover Mode)"
    echo "3) Exit"
    echo "-------------------------------"

    read -p "Choose option (1-3): " CHOICE

    case "\$CHOICE" in
        1) setup_iran ;;
        2) setup_kharej ;;
        3) exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
}

main_menu
