#!/bin/bash

# ==============================
# VXLAN Multi-IP Failover Script
# ==============================

VXLAN_IF="vxlan100"
VXLAN_ID=100

# Local VXLAN IPs (inside tunnel)
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

    # Create failover script (runs on KHAREJ)
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

# Load config from KHAREJ setup
# shellcheck disable=SC1090
source "$CONF_FILE"

# --------- HEALTH & FAILOVER PARAMETERS (TUNABLE) ---------

PRIMARY_INDEX=0           # IRAN[0] is PRIMARY (main Iran server)

PING_COUNT=3              # pings per check
PING_TIMEOUT=1            # seconds per ping

# When is a server fully DOWN?
HARD_DOWN_LOSS=90         # >= this % loss => server considered DOWN

# When is current considered degraded (برای رفتن روی بکاپ)
DEGRADED_LOSS=40          # >= this % => degraded
DEGRADED_RTT=300          # >= this ms => degraded
BAD_STREAK_LIMIT=3        # number of consecutive degraded checks before switching

# شرایط "پایداری" سرور اصلی برای برگشت:
PRIMARY_OK_LOSS=50        # loss <= this%
PRIMARY_OK_RTT=450        # rtt <= this ms
PRIMARY_STABLE_ROUNDS=3   # چند حلقه پشت‌سرهم خوب باشد (با SLEEP=2 یعنی حدود ۶ ثانیه)

SLEEP_INTERVAL=2          # seconds between health checks

# ---------------------------------------------------------

CURRENT=-1                # active IRAN index (-1 means none yet)
CURRENT_BAD_STREAK=0
PRIMARY_GOOD_STREAK=0

declare -a LOSS_ARR
declare -a RTT_ARR

# ------------- PROBE + PARSE PING ------------------------

probe_server() {
    local IP="$1"
    local LOSS=100
    local RTT=1000
    local OUT

    OUT=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$IP" 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        local loss_line
        loss_line=$(echo "$OUT" | grep -m1 "packet loss")
        if [[ -n "$loss_line" ]]; then
            LOSS=$(echo "$loss_line" | awk -F',' '{print $3}' | sed 's/[^0-9]//g')
            [[ -z "$LOSS" ]] && LOSS=0
        else
            LOSS=0
        fi

        local rtt_line
        rtt_line=$(echo "$OUT" | grep -m1 "rtt" || true)
        if [[ -n "$rtt_line" ]]; then
            RTT=$(echo "$rtt_line" | awk -F'/' '{print $5}')
            RTT=${RTT%.*}
            [[ -z "$RTT" ]] && RTT=0
        else
            RTT=50
        fi
    else
        LOSS=100
        RTT=1000
    fi

    echo "$LOSS $RTT"
}

compute_score() {
    local loss="$1"
    local rtt="$2"
    # lower score = better
    echo $(( loss * 100 + rtt ))
}

# ------------- SWITCH VXLAN TO SELECTED IRAN -------------

switch_to_index() {
    local INDEX="$1"
    local REMOTE_IP="${IRAN_IPS[$INDEX]}"

    log "Switching VXLAN to IRAN[index=$INDEX, ip=$REMOTE_IP]"

    local ROUTES=""
    if ip link show "$VXLAN_IF" >/dev/null 2>&1; then
        ROUTES=$(ip route show dev "$VXLAN_IF" 2>/dev/null || true)
    fi

    ip link set "$VXLAN_IF" down >/dev/null 2>&1 || true
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

    if [[ -n "$ROUTES" ]]; then
        log "Restoring routes on $VXLAN_IF:"
        while IFS= read -r R; do
            [[ -z "$R" ]] && continue
            log "  ip route add $R"
            ip route add $R 2>/dev/null || log "WARN: failed to restore route: $R"
        done <<< "$ROUTES"
    fi

    ip neigh flush dev "$VXLAN_IF" 2>/dev/null || true
    bridge fdb flush dev "$VXLAN_IF" 2>/dev/null || true

    CURRENT="$INDEX"
    CURRENT_BAD_STREAK=0
    log "VXLAN is now using IRAN[ip=$REMOTE_IP]"
    return 0
}

# ------------- MAIN MONITOR LOOP -------------------------

monitor_loop() {
    log "Starting VXLAN failover monitor. IRAN IPs: ${IRAN_IPS[*]}"

    while true; do
        local i

        # Probe all IRAN servers
        for ((i=0; i<COUNT; i++)); do
            local IP="${IRAN_IPS[$i]}"
            local loss rtt
            read loss rtt < <(probe_server "$IP")
            LOSS_ARR[$i]=$loss
            RTT_ARR[$i]=$rtt

            local score
            score=$(compute_score "$loss" "$rtt")

            log "Health index=$i ip=$IP loss=${loss}% rtt=${rtt}ms score=$score"
        done

        local curr_loss=100
        local curr_rtt=1000

        if (( CURRENT >= 0 )); then
            curr_loss=${LOSS_ARR[$CURRENT]:-100}
            curr_rtt=${RTT_ARR[$CURRENT]:-1000}
        fi

        local prim_loss=${LOSS_ARR[$PRIMARY_INDEX]:-100}
        local prim_rtt=${RTT_ARR[$PRIMARY_INDEX]:-1000}

        # Track primary stability (برای برگشت روی سرور اصلی)
        if (( prim_loss <= PRIMARY_OK_LOSS && prim_rtt <= PRIMARY_OK_RTT )); then
            PRIMARY_GOOD_STREAK=$((PRIMARY_GOOD_STREAK + 1))
        else
            PRIMARY_GOOD_STREAK=0
        fi

        # Track current degradation (برای رفتن روی بکاپ)
        if (( curr_loss >= DEGRADED_LOSS || curr_rtt >= DEGRADED_RTT )); then
            CURRENT_BAD_STREAK=$((CURRENT_BAD_STREAK + 1))
        else
            CURRENT_BAD_STREAK=0
        fi

        log "Summary: current_index=$CURRENT curr_loss=${curr_loss}% curr_rtt=${curr_rtt}ms | primary_loss=${prim_loss}% primary_rtt=${prim_rtt}ms primary_good_streak=$PRIMARY_GOOD_STREAK bad_streak=$CURRENT_BAD_STREAK"

        # --------- تصمیم‌گیری ---------

        # Case 1: هیچ سرور فعالی نداریم → سعی کن روی primary بری، اگر DOWN بود روی بعدی
        if (( CURRENT < 0 )); then
            if (( prim_loss < HARD_DOWN_LOSS )); then
                log "No active IRAN. PRIMARY seems reachable, switching to PRIMARY."
                switch_to_index "$PRIMARY_INDEX"
            else
                # اگر خود primary هم Down بود، یک بکاپ سالم پیدا کن
                for ((i=0; i<COUNT; i++)); do
                    (( i == PRIMARY_INDEX )) && continue
                    if (( ${LOSS_ARR[$i]:-100} < HARD_DOWN_LOSS )); then
                        log "No active IRAN and PRIMARY is down. Switching to backup index=$i."
                        switch_to_index "$i"
                        break
                    fi
                done
            fi

        else
            # Case 2: سرور فعلی داریم

            # 2a) اگر سرور فعلی کاملاً DOWN شد → برو روی بهترین مورد بعدی
            if (( curr_loss >= HARD_DOWN_LOSS )); then
                log "Current IRAN is effectively DOWN (loss=${curr_loss}%). Looking for alternative..."
                # اولویت با PRIMARY اگر قابل قبول باشد
                if (( prim_loss < HARD_DOWN_LOSS )); then
                    log "PRIMARY is reachable enough. Switching to PRIMARY."
                    switch_to_index "$PRIMARY_INDEX"
                else
                    # PRIMARY هم down است → یکی از بکاپ‌ها را انتخاب کن
                    for ((i=0; i<COUNT; i++)); do
                        (( i == CURRENT )) && continue
                        if (( ${LOSS_ARR[$i]:-100} < HARD_DOWN_LOSS )); then
                            log "Switching to backup index=$i (PRIMARY also bad)."
                            switch_to_index "$i"
                            break
                        fi
                    done
                fi

            else
                # 2b) اگر روی PRIMARY هستیم و degrade شد → برو روی بکاپ
                if (( CURRENT == PRIMARY_INDEX )); then
                    if (( CURRENT_BAD_STREAK >= BAD_STREAK_LIMIT )); then
                        log "PRIMARY degraded for $CURRENT_BAD_STREAK checks. Searching for a better backup..."
                        for ((i=0; i<COUNT; i++)); do
                            (( i == PRIMARY_INDEX )) && continue
                            if (( ${LOSS_ARR[$i]:-100} < HARD_DOWN_LOSS )); then
                                log "Found backup index=$i. Switching from degraded PRIMARY to backup."
                                switch_to_index "$i"
                                break
                            fi
                        done
                        CURRENT_BAD_STREAK=0
                    fi
                else
                    # 2c) اگر روی بکاپ هستیم و PRIMARY چند دور خوب بوده → حتماً برگرد روی PRIMARY
                    if (( PRIMARY_GOOD_STREAK >= PRIMARY_STABLE_ROUNDS )); then
                        log "PRIMARY has been stable for ${PRIMARY_GOOD_STREAK} checks. Switching back to PRIMARY."
                        switch_to_index "$PRIMARY_INDEX"
                        PRIMARY_GOOD_STREAK=0
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
