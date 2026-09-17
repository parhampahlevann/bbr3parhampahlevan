#!/bin/bash
# =========================================================================
# RTT (ReverseTlsTunnel) Installer - v4.1 (Stability & Watchdog Hotfix)
# =========================================================================

#colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'
white='\033[0;37m'
rest='\033[0m'

INSTALL_DIR="/root"
TUNNEL_MSS=1340
MSS_CLAMP_SCRIPT="/usr/local/sbin/rtt-mss-clamp.sh"
MSS_CLAMP_SERVICE="/etc/systemd/system/rtt-mss-clamp.service"
WATCHDOG_SCRIPT="/usr/local/sbin/rtt-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/rtt-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/rtt-watchdog.timer"

if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

root_access() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script requires root access. Please run as root."
        exit 1
    fi
}

other_rtt_services_installed() {
    local exclude=("$@")
    local all_services=(tunnel.service lbtunnel.service custom_tunnel.service)
    for f in /etc/systemd/system/multisni-*.service; do
        [ -e "$f" ] && all_services+=("$(basename "$f")")
    done

    for svc in "${all_services[@]}"; do
        local skip=0
        for ex in "${exclude[@]}"; do
            [ "$svc" == "$ex" ] && skip=1
        done
        [ "$skip" -eq 1 ] && continue
        [ -f "/etc/systemd/system/$svc" ] && return 0
    done
    return 1
}

validate_no_space() {
    local val="$1" label="$2"
    if [[ "$val" == *" "* ]]; then
        echo -e "${red}Error: $label cannot contain spaces. Please run again without spaces.${rest}"
        exit 1
    fi
}

detect_distribution() {
    local supported_distributions=("ubuntu" "debian" "centos" "fedora" "rocky" "almalinux" "rhel")

    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ " ${supported_distributions[*]} " == *" ${ID} "* ]]; then
            package_manager="apt-get"
            case "${ID}" in
                centos|rocky|almalinux|rhel) package_manager="yum" ;;
                fedora) package_manager="dnf" ;;
            esac
        else
            echo "Unsupported distribution!"
            exit 1
        fi
    else
        echo "Unsupported distribution!"
        exit 1
    fi
}

check_dependencies() {
    detect_distribution

    if [ "$package_manager" == "yum" ] && [[ "${ID}" == "centos" || "${ID}" == "rocky" || "${ID}" == "almalinux" ]]; then
        $SUDO "${package_manager}" install -y epel-release 2>/dev/null
    fi

    local dependencies=("wget" "lsof" "iptables" "unzip" "gcc" "git" "curl" "tar" "mtr")

    for dep in "${dependencies[@]}"; do
        if ! command -v "${dep}" &> /dev/null; then
            echo "${dep} is not installed. Installing..."
            $SUDO "${package_manager}" install "${dep}" -y
        fi
    done

    command -v ss &> /dev/null || $SUDO "${package_manager}" install -y iproute2 2>/dev/null || $SUDO "${package_manager}" install -y iproute

    if command -v firewall-cmd &> /dev/null && $SUDO systemctl is-active --quiet firewalld; then
        echo -e "${yellow}firewalld detected and active. Opening 23-65535/tcp...${rest}"
        $SUDO firewall-cmd --permanent --add-port=23-65535/tcp > /dev/null 2>&1
        $SUDO firewall-cmd --reload > /dev/null 2>&1
    fi
}

KEEP_UFW_FLAG=""
prompt_keep_ufw() {
    KEEP_UFW_FLAG=""
    if command -v ufw &> /dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${yellow}UFW is active on this server. By default RTT disables UFW when it starts.${rest}"
        read -p "Keep UFW active instead (adds --keep-ufw)? [yes/no] (default: no): " keep_ufw_choice
        if [ "$keep_ufw_choice" == "yes" ]; then
            KEEP_UFW_FLAG=" --keep-ufw"
        fi
    fi
}

open_ufw_range() {
    if [ -n "$KEEP_UFW_FLAG" ]; then
        $SUDO ufw allow "${1}/tcp" > /dev/null 2>&1
    fi
}

apply_kernel_tuning() {
    echo -e "${cyan}===> Applying kernel/network stability profile...${rest}"

    local cc="bbr"
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
        && ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${yellow}BBR module not available, falling back to cubic + fq_codel.${rest}"
        cc="cubic"
    fi

    cat <<EOF > /etc/sysctl.d/99-rtt-tunnel-tuning.conf
# Congestion control
net.core.default_qdisc = $( [ "$cc" == "bbr" ] && echo fq || echo fq_codel )
net.ipv4.tcp_congestion_control = $cc

# Buffer headroom
net.core.netdev_max_backlog = 10000
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_moderate_rcvbuf = 1

# Tunnel traffic responsiveness
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_frto = 2
net.ipv4.tcp_early_retrans = 3

# Disable TCP FastOpen (prevents DPI drops in Iran)
net.ipv4.tcp_fastopen = 0

# Conservative MTU discovery
net.ipv4.tcp_mtu_probing = 0

# Keepalive & syn limits
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535

net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1

# Standard reordering (re-enables Fast Retransmit on packet loss)
net.ipv4.tcp_reordering = 3
net.ipv4.tcp_max_reordering = 300
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

net.ipv4.tcp_no_metrics_save = 1
fs.file-max = 2097152
EOF

    $SUDO sysctl --system > /dev/null 2>&1

    local nofile_services=(tunnel.service lbtunnel.service custom_tunnel.service)
    for f in /etc/systemd/system/multisni-*.service; do
        [ -e "$f" ] && nofile_services+=("$(basename "$f")")
    done
    for svc in "${nofile_services[@]}"; do
        if [ -f "/etc/systemd/system/$svc" ]; then
            if ! grep -q "LimitNOFILE" "/etc/systemd/system/$svc"; then
                sed -i '/\[Service\]/a LimitNOFILE=1048576' "/etc/systemd/system/$svc"
            fi
        fi
    done

    cat <<EOF > "$MSS_CLAMP_SCRIPT"
#!/bin/bash
IFACE=\$(ip route | grep default | awk '{print \$5}' | head -n1)
if [ -n "\$IFACE" ]; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS 2>/dev/null \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS
    iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS 2>/dev/null \
        || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS
fi
EOF
    chmod +x "$MSS_CLAMP_SCRIPT"
    bash "$MSS_CLAMP_SCRIPT"

    cat <<EOF > "$MSS_CLAMP_SERVICE"
[Unit]
Description=RTT tunnel MSS clamp
After=network.target

[Service]
Type=oneshot
ExecStart=$MSS_CLAMP_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable rtt-mss-clamp.service > /dev/null 2>&1
    $SUDO systemctl start rtt-mss-clamp.service

    echo -e "${green}===> Tuning applied. Congestion control=$(sysctl -n net.ipv4.tcp_congestion_control)${rest}"
}

check_installed() {
    if [ -f "/etc/systemd/system/tunnel.service" ]; then
        echo "The service is already installed."
        exit 1
    fi
}

install_selected_version() {
    read -p "Do you want to install the Latest version? [yes/no] (default: yes): " choice
    if [[ "$choice" == "no" ]]; then
        install_rtt_custom
    else
        install_rtt
    fi
}

install_rtt() {
    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; exit 1; }

    if pgrep -x "RTT" > /dev/null && [ ! -f "$INSTALL_DIR/RTT" ]; then
        echo -e "${yellow}Cleaning up orphaned RTT process...${rest}"
        pkill -x RTT 2>/dev/null
        sleep 1
    fi

    if ! wget "https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh" -O install.sh; then
        echo -e "${red}Failed to download install.sh.${rest}"
        exit 1
    fi
    chmod +x install.sh

    if ! bash install.sh; then
        echo -e "${red}install.sh failed to run correctly.${rest}"
        exit 1
    fi

    if [ ! -f "$INSTALL_DIR/RTT" ]; then
        echo -e "${red}RTT binary not found after install.${rest}"
        exit 1
    fi

    restart_all_rtt_services
}

restart_all_rtt_services() {
    for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
        if [ -f "/etc/systemd/system/$svc" ]; then
            $SUDO systemctl restart "$svc" 2>/dev/null
        fi
    done
    for f in /etc/systemd/system/multisni-*.service; do
        [ -e "$f" ] && $SUDO systemctl restart "$(basename "$f")" 2>/dev/null
    done
}

install_rtt_custom() {
    local was_running=0
    if pgrep -x "RTT" > /dev/null; then
        was_running=1
        for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
            [ -f "/etc/systemd/system/$svc" ] && $SUDO systemctl stop "$svc" 2>/dev/null
        done
        for f in /etc/systemd/system/multisni-*.service; do
            [ -e "$f" ] && $SUDO systemctl stop "$(basename "$f")" 2>/dev/null
        done
        pkill -x RTT 2>/dev/null
        sleep 1
    fi

    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; exit 1; }
    read -p "Please enter your custom version (e.g. 7.1): " version

    case "$(uname -m)" in
        x86_64)
            URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V${version}/v${version}_linux_amd64.zip"
            OUT_FILE="v${version}_linux_amd64.zip"
            ;;
        aarch64|arm64)
            URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V${version}/v${version}_linux_arm64.zip"
            OUT_FILE="v${version}_linux_arm64.zip"
            ;;
        *)
            echo "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    if ! wget "$URL" -O "$OUT_FILE"; then
        echo -e "${red}Failed to download RTT version $version.${rest}"
        exit 1
    fi

    if ! unzip -o "$OUT_FILE"; then
        echo -e "${red}Failed to unzip $OUT_FILE.${rest}"
        exit 1
    fi

    chmod +x RTT
    rm -f "$OUT_FILE"

    if [ "$was_running" -eq 1 ]; then
        restart_all_rtt_services
    fi
}

configure_arguments() {
    read -p "Which server do you want to use? (1 for Iran, 2 for Kharej): " server_choice
    read -p "Please enter SNI (default: sheypoor.com): " sni
    sni=${sni:-sheypoor.com}
    validate_no_space "$sni" "SNI"

    prompt_keep_ufw

    if [ "$server_choice" == "2" ]; then
        read -p "Please enter IRAN IP (internal-server): " server_ip
        validate_no_space "$server_ip" "IRAN IP"
        read -p "Please enter password: " password
        validate_no_space "$password" "password"
        arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni$KEEP_UFW_FLAG"
    elif [ "$server_choice" == "1" ]; then
        read -p "Please enter password: " password
        validate_no_space "$password" "password"
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g. 5 for 5:1): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password --noise:$upload_ratio$KEEP_UFW_FLAG"
        else
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password$KEEP_UFW_FLAG"
        fi
        open_ufw_range "23:65535"
    else
        echo "Invalid choice. Please enter '1' or '2'."
        exit 1
    fi
}

install() {
    root_access
    check_dependencies
    check_installed
    install_selected_version

    configure_arguments

    cd /etc/systemd/system || exit 1

    cat <<EOL > tunnel.service
[Unit]
Description=RTT Tunnel Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/RTT $arguments
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable tunnel.service
    $SUDO systemctl restart tunnel.service

    apply_kernel_tuning
    install_watchdog

    sleep 2
    if $SUDO systemctl is-active --quiet tunnel.service; then
        echo -e "${green}Tunnel service started successfully.${rest}"
    else
        echo -e "${red}Tunnel service failed to start! Check: journalctl -u tunnel.service -n 50${rest}"
    fi
}

check_lbinstalled() {
    if [ -f "/etc/systemd/system/lbtunnel.service" ]; then
        echo "The Load-balancer is already installed."
        exit 1
    fi
}

configure_arguments2() {
    read -p "Which server do you want to use? (1 for Iran, 2 for Kharej): " server_choice
    read -p "Please enter SNI (default: sheypoor.com): " sni
    sni=${sni:-sheypoor.com}
    validate_no_space "$sni" "SNI"

    prompt_keep_ufw

    if [ "$server_choice" == "2" ]; then
        read -p "Is this your main server (VPN server)? (yes/no): " is_main_server
        read -p "Please enter IRAN IP: " server_ip
        validate_no_space "$server_ip" "IRAN IP"
        read -p "Please enter password: " password
        validate_no_space "$password" "password"

        if [ "$is_main_server" == "yes" ]; then
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni$KEEP_UFW_FLAG"
        else
            read -p "Enter your main IP (VPN server): " main_ip
            validate_no_space "$main_ip" "main IP"
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:$main_ip --toport:multiport --password:$password --sni:$sni$KEEP_UFW_FLAG"
        fi

    elif [ "$server_choice" == "1" ]; then
        read -p "Please enter password: " password
        validate_no_space "$password" "password"
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g. 5 for 5:1): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni --noise:$upload_ratio$KEEP_UFW_FLAG"
        else
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni$KEEP_UFW_FLAG"
        fi
        open_ufw_range "23:65535"

        num_ips=0
        while true; do
            ((num_ips++))
            read -p "Please enter IP of peer server $num_ips (or type 'done' to finish): " ip
            if [ "$ip" == "done" ]; then
                break
            else
                validate_no_space "$ip" "peer IP"
                arguments="$arguments --peer:$ip"
            fi
        done
    else
        echo "Invalid choice. Please enter '1' or '2'."
        exit 1
    fi
}

load-balancer() {
    root_access
    check_dependencies
    check_lbinstalled
    install_selected_version
    configure_arguments2

    cd /etc/systemd/system || exit 1

    cat <<EOL > lbtunnel.service
[Unit]
Description=RTT Load-balancer Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/RTT $arguments
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable lbtunnel.service
    $SUDO systemctl restart lbtunnel.service

    apply_kernel_tuning
    install_watchdog
}

lb_uninstall() {
    if [ ! -f "/etc/systemd/system/lbtunnel.service" ]; then
        echo "The Load-balancer is not installed."
        return
    fi
    $SUDO systemctl stop lbtunnel.service
    $SUDO systemctl disable lbtunnel.service
    $SUDO rm -f /etc/systemd/system/lbtunnel.service
    $SUDO systemctl reset-failed
    if ! other_rtt_services_installed "lbtunnel.service"; then
        $SUDO rm -f "$INSTALL_DIR/RTT" "$INSTALL_DIR/install.sh" 2>/dev/null
    fi
    echo "Uninstallation completed successfully."
}

uninstall() {
    if [ ! -f "/etc/systemd/system/tunnel.service" ]; then
        echo "The service is not installed."
        return
    fi
    $SUDO systemctl stop tunnel.service
    $SUDO systemctl disable tunnel.service
    $SUDO rm -f /etc/systemd/system/tunnel.service
    $SUDO systemctl reset-failed
    if ! other_rtt_services_installed "tunnel.service"; then
        $SUDO rm -f "$INSTALL_DIR/RTT" "$INSTALL_DIR/install.sh" 2>/dev/null
    fi
    echo "Uninstallation completed successfully."
}

version_gt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

update_services() {
    cd "$INSTALL_DIR" || exit 1
    installed_version=$(./RTT -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    latest_version=$(curl -s https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest \
        | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^[Vv]//')

    if [ -z "$latest_version" ]; then
        echo -e "${red}Could not fetch latest version from GitHub API.${rest}"
        return 1
    fi

    if version_gt "$latest_version" "$installed_version"; then
        echo "Updating to $latest_version..."
        restart_all_rtt_services
        echo "Updated."
    else
        echo "Already latest version ($installed_version)."
    fi
}

start_tunnel() {
    $SUDO systemctl restart tunnel.service
    check_tunnel_status
}

stop_tunnel() {
    $SUDO systemctl stop tunnel.service
    check_tunnel_status
}

check_tunnel_status() {
    if $SUDO systemctl is-active --quiet tunnel.service; then
        echo -e "${yellow}Multiport is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Multiport is:${red} [Not running]${rest}"
    fi
}

start_lb_tunnel() {
    $SUDO systemctl restart lbtunnel.service
    check_lb_tunnel_status
}

stop_lb_tunnel() {
    $SUDO systemctl stop lbtunnel.service
    check_lb_tunnel_status
}

check_lb_tunnel_status() {
    if $SUDO systemctl is-active --quiet lbtunnel.service; then
        echo -e "${yellow}Load balancer is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Load balancer is:${red}[Not running]${rest}"
    fi
}

install_custom() {
    root_access
    check_dependencies
    install_selected_version
    read -p "Enter RTT arguments: " arguments

    cat <<EOL > /etc/systemd/system/custom_tunnel.service
[Unit]
Description=RTT Custom Tunnel Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$arguments
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable custom_tunnel.service
    $SUDO systemctl restart custom_tunnel.service
    apply_kernel_tuning
    install_watchdog
}

change_sni() {
    root_access
    local services=()
    for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
        [ -f "/etc/systemd/system/$svc" ] && services+=("$svc")
    done
    for f in /etc/systemd/system/multisni-*.service; do
        [ -e "$f" ] && services+=("$(basename "$f")")
    done

    if [ ${#services[@]} -eq 0 ]; then
        echo -e "${red}No RTT service installed.${rest}"
        return
    fi

    local target_svc="${services[0]}"
    local svc_path="/etc/systemd/system/$target_svc"
    local current_sni
    current_sni=$(grep "ExecStart=" "$svc_path" | sed -n 's/.*--sni:\([^ ]*\).*/\1/p')
    echo -e "Current SNI: ${cyan}$current_sni${rest}"
    read -p "Enter new SNI: " new_sni
    validate_no_space "$new_sni" "SNI"

    if [ -n "$new_sni" ]; then
        sed -i "s/--sni:[^ ]*/--sni:$new_sni/" "$svc_path"
        $SUDO systemctl daemon-reload
        $SUDO systemctl restart "$target_svc"
        echo -e "${green}SNI updated to $new_sni and service restarted.${rest}"
    fi
}

install_haproxy() {
    root_access
    detect_distribution
    $SUDO "${package_manager}" install -y haproxy
    echo -e "${green}HAProxy installed.${rest}"
}

install_watchdog() {
    root_access
    echo -e "${cyan}===> Installing the stabilized connection watchdog...${rest}"
    mkdir -p /var/lib/rtt-watchdog

    cat <<'WDEOF' > /usr/local/sbin/rtt-watchdog.sh
#!/bin/bash
# Fixed RTT Watchdog: Prevents false-positive restart loops

STATE_DIR="/var/lib/rtt-watchdog"
mkdir -p "$STATE_DIR"

log() {
    logger -t rtt-watchdog -- "$1"
}

# Increased cooldown to 120s to eliminate restart storms
MIN_RESTART_GAP=120

restart_service() {
    local svc="$1"
    local reason="$2"
    local last_file="$STATE_DIR/${svc}.last_restart"
    local now
    now=$(date +%s)

    if [ -f "$last_file" ]; then
        local last diff
        last=$(cat "$last_file" 2>/dev/null || echo 0)
        diff=$((now - last))
        if [ "$diff" -lt "$MIN_RESTART_GAP" ]; then
            log "$svc: needs restart ($reason) but cooled down for ${diff}s - skipping."
            return
        fi
    fi

    log "$svc: restarting - $reason"
    systemctl reset-failed "$svc" 2>/dev/null
    systemctl restart "$svc" 2>/dev/null
    echo "$now" > "$last_file"
}

check_service() {
    local svc="$1"
    local svc_path="/etc/systemd/system/$svc"
    [ -f "$svc_path" ] || return

    systemctl is-enabled --quiet "$svc" 2>/dev/null || return

    # Check 1: Systemd inactive/crashed state
    if ! systemctl is-active --quiet "$svc"; then
        restart_service "$svc" "service is inactive or crashed"
        return
    fi

    # Check 2: Process check (ensure RTT PID is truly alive and responsive)
    local main_pid
    main_pid=$(systemctl show -p MainPID --value "$svc")
    if [ -z "$main_pid" ] || [ "$main_pid" -le 0 ] || ! kill -0 "$main_pid" 2>/dev/null; then
        restart_service "$svc" "main process PID $main_pid is dead"
        return
    fi

    # Check 3: Check if process is stuck in Uninterruptible Sleep (D-state)
    local proc_state
    proc_state=$(ps -o state= -p "$main_pid" 2>/dev/null | tr -d ' ')
    if [ "$proc_state" == "D" ]; then
        restart_service "$svc" "process is stuck in D-state"
        return
    fi
}

for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
    check_service "$svc"
done

for f in /etc/systemd/system/multisni-*.service; do
    [ -e "$f" ] || continue
    check_service "$(basename "$f")"
done
WDEOF
    chmod +x /usr/local/sbin/rtt-watchdog.sh

    cat <<EOF > "$WATCHDOG_SERVICE"
[Unit]
Description=RTT tunnel watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

    cat <<EOF > "$WATCHDOG_TIMER"
[Unit]
Description=Run RTT tunnel watchdog periodically

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now rtt-watchdog.timer > /dev/null 2>&1
    echo -e "${green}Fixed watchdog installed (checks safely every 60s without false positives).${rest}"
}

uninstall_watchdog() {
    root_access
    $SUDO systemctl disable --now rtt-watchdog.timer 2>/dev/null
    $SUDO systemctl stop rtt-watchdog.service 2>/dev/null
    $SUDO rm -f "$WATCHDOG_TIMER" "$WATCHDOG_SERVICE" "$WATCHDOG_SCRIPT"
    $SUDO systemctl daemon-reload
    echo "Watchdog removed."
}

show_watchdog_log() {
    journalctl -t rtt-watchdog -n 50 --no-pager
}

# ip & version
myip=$(hostname -I | awk '{print $1}')
version=$([ -f "$INSTALL_DIR/RTT" ] && "$INSTALL_DIR/RTT" -v 2>&1 | grep -o 'version="[0-9.]*"')

clear
echo -e "${cyan}Radkesvat Fixed By Parham Pahlean (v4.1 Patched)${rest}"
echo -e "Your IP is: ${cyan}($myip)${rest} "
echo -e "${yellow}******************************${rest}"
check_tunnel_status
check_lb_tunnel_status
echo -e "${yellow}******************************${rest}"
echo -e "${green}1) Install (Multiport)${rest}"
echo -e "${red}2) Uninstall (Multiport)${rest}"
echo "3) Start Multiport"
echo "4) Stop Multiport"
echo "5) Check Status"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${green}6) Install Load-balancer${rest}"
echo -e "${red}7) Uninstall Load-balancer${rest}"
echo -e "${purple}18) Re-apply kernel tuning profile only${rest}"
echo -e "${cyan}19) Change Tunnel SNI${rest}"
echo -e "${green}24) Reinstall fixed watchdog${rest}"
echo -e "${cyan}25) Show watchdog log${rest}"
echo -e "${red}26) Uninstall watchdog${rest}"
echo "0) Exit"
read -p "Please choose: " choice

case $choice in
    1) install ;;
    2) uninstall ;;
    3) start_tunnel ;;
    4) stop_tunnel ;;
    5) check_tunnel_status ;;
    6) load-balancer ;;
    7) lb_uninstall ;;
    18) root_access; apply_kernel_tuning ;;
    19) change_sni ;;
    24) install_watchdog ;;
    25) show_watchdog_log ;;
    26) uninstall_watchdog ;;
    0) exit ;;
    *) echo "Invalid choice." ;;
esac
