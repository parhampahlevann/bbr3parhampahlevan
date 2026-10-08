#!/bin/bash
# =========================================================================
# RTT (ReverseTlsTunnel) Installer - v4.3 (Stability & Low-Latency Edition)
#
# Changes vs v4.2:
#   Watchdog : restarts only after 3 consecutive failed checks (~2-3 min),
#              hourly soft-restart budget, and the Kharej side now checks its
#              real established session to the Iran server (v4.2 did not).
#   Kernel   : TCP buffers capped at 16 MB (less RAM per socket on small VPS),
#              MTU probing enabled (fallback when ICMP is filtered),
#              tcp_notsent_lowat for lower interactive latency.
#   Service  : RestartSec 5 -> 3 (new installs), diagnostics menu item (29).
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

# Extract a value such as --iran-ip:1.2.3.4 from an ExecStart line.
get_exec_arg() {
    echo "$1" | sed -n "s/.*--$2:\([^ ]*\).*/\1/p"
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

# Buffers: 16 MB ceiling is roughly 500 Mbit/s at 250 ms RTT (bandwidth-delay
# product). Larger ceilings only raise RAM use per socket on small VPS.
net.core.netdev_max_backlog = 10000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
net.ipv4.tcp_moderate_rcvbuf = 1

# Latency: do not let unsent data pile up in socket buffers
net.ipv4.tcp_notsent_lowat = 16384

# Tunnel traffic responsiveness
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_frto = 2
net.ipv4.tcp_early_retrans = 3

# TCP FastOpen off: no measured benefit for this tunnel, kept predictable
net.ipv4.tcp_fastopen = 0

# PMTU black-hole fallback: ICMP "fragmentation needed" is often filtered,
# so probing lets TCP recover instead of stalling on large transfers
net.ipv4.tcp_mtu_probing = 1

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

# Standard reordering tolerance
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
for chain in FORWARD INPUT OUTPUT; do
    iptables -t mangle -C \$chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS 2>/dev/null || iptables -t mangle -A \$chain -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS
done
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
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable tunnel.service
    $SUDO systemctl restart tunnel.service

    apply_kernel_tuning
    install_watchdog

    sleep 3
    if ! $SUDO systemctl is-active --quiet tunnel.service; then
        echo -e "${red}Tunnel service failed to start! Check: journalctl -u tunnel.service -n 50${rest}"
    elif [ "$server_choice" == "1" ]; then
        # Iran role: RTT must actually bind a listening socket. is-active alone
        # does not prove that - it only proves the process launched.
        sleep 2
        local pid
        pid=$($SUDO systemctl show -p MainPID --value tunnel.service)
        if [ -n "$pid" ] && [ "$pid" -gt 0 ] && ss -tlnp 2>/dev/null | grep -q "pid=${pid},"; then
            echo -e "${green}Tunnel service started successfully and is listening.${rest}"
        else
            echo -e "${yellow}Tunnel service is running but is NOT listening yet.${rest}"
            echo -e "${yellow}Give it a few more seconds, then check: journalctl -u tunnel.service -n 50${rest}"
        fi
    else
        echo -e "${green}Tunnel service started successfully.${rest}"
        echo -e "${yellow}Note: this is a Kharej client - it makes an outbound connection, it won't show as 'listening'. Confirm the Iran side sees an active peer too.${rest}"
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
RestartSec=3
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
    root_access
    cd "$INSTALL_DIR" || exit 1
    installed_version=$(./RTT -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    latest_version=$(curl -s https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest \
        | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^[Vv]//')

    if [ -z "$latest_version" ]; then
        echo -e "${red}Could not fetch latest version from GitHub API.${rest}"
        return 1
    fi

    if version_gt "$latest_version" "$installed_version"; then
        echo "Updating from ${installed_version:-unknown} to $latest_version..."
        if wget "https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh" -O install.sh; then
            chmod +x install.sh
            if bash install.sh; then
                restart_all_rtt_services
                echo -e "${green}Updated to $latest_version and restarted.${rest}"
            else
                echo -e "${red}install.sh failed - binary was NOT updated.${rest}"
            fi
        else
            echo -e "${red}Failed to download the installer - binary was NOT updated.${rest}"
        fi
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
RestartSec=3
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
    echo -e "${cyan}===> Installing the stabilized connection watchdog (v4.3)...${rest}"
    mkdir -p /var/lib/rtt-watchdog

    cat <<'WDEOF' > /usr/local/sbin/rtt-watchdog.sh
#!/bin/bash
# RTT watchdog v4.3 - restarts only after repeated, confirmed failures.

STATE_DIR="/var/lib/rtt-watchdog"
mkdir -p "$STATE_DIR"

STRIKE_LIMIT=3          # consecutive failed checks (60s apart) before a soft restart
MAX_SOFT_RESTARTS_H=3   # max soft restarts per service per hour
MIN_RESTART_GAP=180     # seconds between two restarts of the same service
STARTUP_GRACE=60        # seconds after (re)start before a process is judged

log() {
    logger -t rtt-watchdog -- "$1"
}

get_arg() {
    echo "$1" | sed -n "s/.*--$2:\([^ ]*\).*/\1/p"
}

# restart_service <svc> <reason> <hard|soft>
restart_service() {
    local svc="$1" reason="$2" kind="$3"
    local hist="$STATE_DIR/${svc}.restarts"
    local now last count
    now=$(date +%s)
    touch "$hist"

    last=$(tail -n1 "$hist")
    last=${last:-0}
    if [ $((now - last)) -lt "$MIN_RESTART_GAP" ]; then
        log "$svc: $reason - last restart $((now - last))s ago, skipping"
        return
    fi

    if [ "$kind" == "soft" ]; then
        awk -v t=$((now - 3600)) '$1 > t' "$hist" > "$hist.tmp" && mv "$hist.tmp" "$hist"
        count=$(wc -l < "$hist")
        if [ "$count" -ge "$MAX_SOFT_RESTARTS_H" ]; then
            log "$svc: $reason - hourly restart budget used ($count), not restarting"
            return
        fi
    fi

    log "$svc: restarting - $reason"
    systemctl reset-failed "$svc" 2>/dev/null
    systemctl restart "$svc" 2>/dev/null
    echo "$now" >> "$hist"
}

# strike <svc> <reason>: count a failed check; restart only when confirmed
strike() {
    local svc="$1" reason="$2"
    local f="$STATE_DIR/${svc}.strikes" n
    n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
    if [ "$n" -lt "$STRIKE_LIMIT" ]; then
        echo "$n" > "$f"
        log "$svc: check failed ($reason) [$n/$STRIKE_LIMIT]"
        return
    fi
    echo 0 > "$f"
    restart_service "$svc" "$reason (confirmed after $STRIKE_LIMIT checks)" soft
}

clear_strike() {
    echo 0 > "$STATE_DIR/${1}.strikes"
}

check_service() {
    local svc="$1"
    local svc_path="/etc/systemd/system/$svc"
    [ -f "$svc_path" ] || return
    systemctl is-enabled --quiet "$svc" 2>/dev/null || return

    # Hard failures: service down or process gone. Restart right away.
    if ! systemctl is-active --quiet "$svc"; then
        restart_service "$svc" "service inactive or crashed" hard
        return
    fi

    local main_pid
    main_pid=$(systemctl show -p MainPID --value "$svc")
    if [ -z "$main_pid" ] || [ "$main_pid" -le 0 ] || ! kill -0 "$main_pid" 2>/dev/null; then
        restart_service "$svc" "main PID $main_pid is dead" hard
        return
    fi

    # Give a freshly (re)started process time to connect before judging it
    local start_ts uptime
    start_ts=$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$svc")" +%s 2>/dev/null || echo 0)
    uptime=$(( $(date +%s) - start_ts ))
    if [ "$uptime" -lt "$STARTUP_GRACE" ]; then
        return
    fi

    local proc_state
    proc_state=$(ps -o state= -p "$main_pid" 2>/dev/null | tr -d ' ')
    if [ "$proc_state" == "D" ]; then
        strike "$svc" "process stuck in D-state"
        return
    fi

    local exec_line
    exec_line=$(grep -m1 "^ExecStart=" "$svc_path")

    if [[ "$exec_line" == *" --iran"* && "$exec_line" != *"--iran-ip"* ]]; then
        # Iran role: the RTT process must own a listening socket
        if ss -tlnp 2>/dev/null | grep -q "pid=${main_pid},"; then
            clear_strike "$svc"
        else
            strike "$svc" "process running but not listening"
        fi
    else
        # Kharej role: an outbound client has no listening socket. Its health
        # is the established session to the Iran server.
        local iran_ip iran_port
        iran_ip=$(get_arg "$exec_line" "iran-ip")
        iran_port=$(get_arg "$exec_line" "iran-port")
        iran_port=${iran_port:-443}

        # Only IPv4 literals are checked; otherwise we cannot judge reliably
        if ! [[ "$iran_ip" =~ ^[0-9.]+$ ]]; then
            clear_strike "$svc"
            return
        fi

        if ss -Htnp state established dst "${iran_ip}:${iran_port}" 2>/dev/null | grep -q "pid=${main_pid},"; then
            clear_strike "$svc"
        else
            strike "$svc" "no established session to ${iran_ip}:${iran_port}"
        fi
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
    echo -e "${green}Watchdog v4.3 installed (checks every 60s, restarts only after 3 confirmed failures).${rest}"
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

diagnose() {
    root_access
    echo -e "${cyan}===> Connection diagnostics${rest}"
    echo "Congestion control : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
        echo "conntrack entries  : $(cat /proc/sys/net/netfilter/nf_conntrack_count)/$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
    fi

    for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
        [ -f "/etc/systemd/system/$svc" ] || continue
        local pid exec_line starts ip port
        pid=$(systemctl show -p MainPID --value "$svc")
        exec_line=$(grep -m1 "^ExecStart=" "/etc/systemd/system/$svc")
        starts=$(journalctl -u "$svc" --since "1 hour ago" --no-pager 2>/dev/null | grep -c "Started ")
        echo -e "${yellow}[$svc]${rest} active=$(systemctl is-active "$svc") pid=$pid starts_last_hour=$starts"

        if [[ "$exec_line" == *" --iran"* && "$exec_line" != *"--iran-ip"* ]]; then
            echo "  listening sockets of RTT : $(ss -tlnp 2>/dev/null | grep -c "pid=${pid},")"
            echo "  owner of port 443        : $(ss -tlnp 'sport = :443' 2>/dev/null | tail -n +2)"
        else
            ip=$(get_exec_arg "$exec_line" "iran-ip")
            port=$(get_exec_arg "$exec_line" "iran-port")
            port=${port:-443}
            echo "  established to ${ip}:${port} : $(ss -Htnp state established dst "${ip}:${port}" 2>/dev/null | grep -c "pid=${pid},")"
            if [ -n "$ip" ]; then
                if ping -M do -c 2 -W 2 -s 1372 "$ip" > /dev/null 2>&1; then
                    echo "  MTU 1400 path test       : OK"
                else
                    echo "  MTU 1400 path test       : FAILED (MTU or ICMP problem; check plain ping first)"
                fi
            fi
        fi
    done

    echo -e "${yellow}Last watchdog events:${rest}"
    journalctl -t rtt-watchdog -n 15 --no-pager 2>/dev/null
}

# ip & version
myip=$(hostname -I | awk '{print $1}')
version=$([ -f "$INSTALL_DIR/RTT" ] && "$INSTALL_DIR/RTT" -v 2>&1 | grep -o 'version="[0-9.]*"')

clear
echo -e "${cyan}Radkesvat Fixed By Parham Pahlean (v4.3 Stability Edition)${rest}"
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
echo -e "${purple}27) Update RTT binary to latest version${rest}"
echo -e "${purple}28) Install HAProxy (optional)${rest}"
echo -e "${green}29) Connection diagnostics${rest}"
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
    27) update_services ;;
    28) install_haproxy ;;
    29) diagnose ;;
    0) exit ;;
    *) echo "Invalid choice." ;;
esac
