#!/bin/bash
# =========================================================================
# RTT (ReverseTlsTunnel) Installer - v3
# Full rewrite (English) with a stronger network/kernel stability profile,
# automatic tuning on install, in-place SNI change, and HAProxy port
# forwarding.
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

root_access() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script requires root access. Please run as root."
        exit 1
    fi
}

detect_distribution() {
    local supported_distributions=("ubuntu" "debian" "centos" "fedora")

    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "${ID}" = "ubuntu" || "${ID}" = "debian" || "${ID}" = "centos" || "${ID}" = "fedora" ]]; then
            package_manager="apt-get"
            [ "${ID}" = "centos" ] && package_manager="yum"
            [ "${ID}" = "fedora" ] && package_manager="dnf"
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

    local dependencies=("wget" "lsof" "iptables" "unzip" "gcc" "git" "curl" "tar" "mtr")

    for dep in "${dependencies[@]}"; do
        if ! command -v "${dep}" &> /dev/null; then
            echo "${dep} is not installed. Installing..."
            sudo "${package_manager}" install "${dep}" -y
        fi
    done

    command -v ss &> /dev/null || sudo "${package_manager}" install -y iproute2 2>/dev/null || sudo "${package_manager}" install -y iproute

    # CentOS/Fedora usually run firewalld; RTT itself only disables ufw.
    if command -v firewall-cmd &> /dev/null && sudo systemctl is-active --quiet firewalld; then
        echo -e "${yellow}firewalld detected and active. Opening 23-65535/tcp...${rest}"
        sudo firewall-cmd --permanent --add-port=23-65535/tcp > /dev/null 2>&1
        sudo firewall-cmd --reload > /dev/null 2>&1
    fi
}

# =========================================================================
# Kernel / network stability profile.
#
# Rationale (based on live diagnostics on an Iran <-> foreign RTT link):
#   - BBR + fq: much better behavior than cubic under high latency/jitter
#     international paths.
#   - tcp_mtu_probing: enables automatic PMTUD black-hole detection/repair.
#     This matters because ICMP "fragmentation needed" packets are commonly
#     rate-limited or dropped on Iran <-> abroad backbone paths, which
#     silently breaks classic PMTU discovery and causes stalls/timeouts
#     that look like random instability.
#   - tcp_reordering / tcp_max_reordering raised: international backbones
#     (e.g. ECMP load-balancing across parallel links) frequently deliver
#     packets out of order. With default settings TCP mistakes this for
#     loss and triggers unnecessary retransmits/backoffs, which is a major
#     source of the "ping spikes" users report even when the underlying
#     link has 0% real loss.
#   - Balanced buffers: large enough to avoid starving throughput, not so
#     large that they cause bufferbloat under load.
#   - Fixed MSS clamp (not PMTU-based): since ICMP is unreliable on this
#     path, a static clamp avoids relying on ICMP-driven PMTU discovery.
#   - Faster dead-connection detection via keepalive + syn/synack retries,
#     so the tunnel recovers quickly instead of hanging on a half-dead
#     socket.
#
# This function is idempotent: safe to run multiple times.
# =========================================================================
apply_kernel_tuning() {
    echo -e "${cyan}===> Applying kernel/network stability profile...${rest}"

    modprobe tcp_bbr 2>/dev/null

    local cc="bbr"
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
        && ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${yellow}BBR module not available on this kernel, falling back to cubic + fq_codel.${rest}"
        cc="cubic"
    fi

    cat <<EOF > /etc/sysctl.d/99-rtt-tunnel-tuning.conf
# --- Congestion control ---
net.core.default_qdisc = $( [ "$cc" == "bbr" ] && echo fq || echo fq_codel )
net.ipv4.tcp_congestion_control = $cc

# --- Avoid bufferbloat while still allowing headroom for throughput ---
net.core.netdev_max_backlog = 5000
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.tcp_moderate_rcvbuf = 1

# --- Better behavior for bursty/idle tunnel traffic ---
net.ipv4.tcp_slow_start_after_idle = 0

# --- Faster, smarter reaction to genuine packet loss ---
net.ipv4.tcp_frto = 2
net.ipv4.tcp_early_retrans = 3

# --- PMTUD black-hole detection/repair (important when ICMP is filtered) ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024

# --- Faster TCP handshake ---
net.ipv4.tcp_fastopen = 3

# --- Faster failure detection so dead attempts don't hang the tunnel ---
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# --- Headroom for many parallel mux connections ---
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535

# --- Half-closed connection handling / reconnect stability ---
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_tw_reuse = 1

# --- Tolerate heavy packet reordering (key fix for ECMP international paths) ---
net.ipv4.tcp_reordering = 127
net.ipv4.tcp_max_reordering = 300

# --- Don't cache stale path metrics between connections on multipath routes ---
net.ipv4.tcp_no_metrics_save = 1

# --- Higher open-file ceiling for mux with many concurrent sockets ---
fs.file-max = 2097152
EOF

    sysctl --system > /dev/null 2>&1

    # LimitNOFILE on all installed RTT services
    for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
        if [ -f "/etc/systemd/system/$svc" ]; then
            if ! grep -q "LimitNOFILE" "/etc/systemd/system/$svc"; then
                sed -i '/\[Service\]/a LimitNOFILE=1048576' "/etc/systemd/system/$svc"
            fi
        fi
    done

    # Fixed MSS clamp, applied now and persisted across reboot via a
    # small oneshot systemd service (iptables rules don't survive reboot
    # by default).
    cat <<EOF > "$MSS_CLAMP_SCRIPT"
#!/bin/bash
IFACE=\$(ip route | grep default | awk '{print \$5}' | head -n1)
if [ -n "\$IFACE" ]; then
    iptables -t mangle -C FORWARD -o "\$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS 2>/dev/null \\
        || iptables -t mangle -A FORWARD -o "\$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS
    iptables -t mangle -C OUTPUT -o "\$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS 2>/dev/null \\
        || iptables -t mangle -A OUTPUT -o "\$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $TUNNEL_MSS
fi
EOF
    chmod +x "$MSS_CLAMP_SCRIPT"
    bash "$MSS_CLAMP_SCRIPT"

    cat <<EOF > "$MSS_CLAMP_SERVICE"
[Unit]
Description=RTT tunnel MSS clamp (persists across reboot)
After=network.target

[Service]
Type=oneshot
ExecStart=$MSS_CLAMP_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable rtt-mss-clamp.service > /dev/null 2>&1
    sudo systemctl start rtt-mss-clamp.service

    echo -e "${green}===> Tuning applied. congestion_control=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)${rest}"
}

check_installed() {
    if [ -f "/etc/systemd/system/tunnel.service" ]; then
        echo "The service is already installed."
        exit 1
    fi
}

install_selected_version() {
    read -p "Do you want to install the Latest version? [yes/no] default: yes): " choice

    if [[ "$choice" == "no" ]]; then
        install_rtt_custom
    else
        install_rtt
    fi
}

install_rtt() {
    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; exit 1; }

    if ! wget "https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh" -O install.sh; then
        echo -e "${red}Failed to download install.sh. Check your internet/DNS/GitHub access.${rest}"
        exit 1
    fi
    chmod +x install.sh

    if ! bash install.sh; then
        echo -e "${red}install.sh failed to run correctly.${rest}"
        exit 1
    fi

    if [ ! -f "$INSTALL_DIR/RTT" ]; then
        echo -e "${red}RTT binary not found after install. Aborting before creating a broken service.${rest}"
        exit 1
    fi
}

install_rtt_custom() {
    if pgrep -x "RTT" > /dev/null; then
        echo "Tunnel is running! You must stop the tunnel before update. (pkill RTT)"
        echo "Update is canceled."
        exit 1
    fi

    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; exit 1; }

    read -p "Please enter your custom version (e.g. 7.1): " version
    apt-get update -y 2>/dev/null

    echo "Downloading ReverseTlsTunnel version: $version"
    printf "\n"

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
            echo "Unsupported/undetected architecture: $(uname -m)"
            exit 1
            ;;
    esac

    if ! wget "$URL" -O "$OUT_FILE"; then
        echo -e "${red}Failed to download RTT version $version. Check the version number and your internet access.${rest}"
        exit 1
    fi

    if ! unzip -o "$OUT_FILE"; then
        echo -e "${red}Failed to unzip $OUT_FILE (corrupted download?).${rest}"
        exit 1
    fi

    chmod +x RTT
    rm -f "$OUT_FILE"

    if [ ! -f "$INSTALL_DIR/RTT" ]; then
        echo -e "${red}RTT binary missing after extraction. Aborting.${rest}"
        exit 1
    fi

    echo "Finished."
}

configure_arguments() {
    read -p "Which server do you want to use? (Enter '1' for Iran/internal-server or '2' for Kharej/external-server): " server_choice
    read -p "Please enter SNI (default: sheypoor.com): " sni
    sni=${sni:-sheypoor.com}

    # --connection-age is used instead of the deprecated/unrecognized
    # --terminate flag, which can cause the binary to error out and get
    # stuck in a systemd restart loop on current releases.
    local stability_flag="--connection-age:4800"

    if [ "$server_choice" == "2" ]; then
        read -p "Please enter IRAN IP (internal-server): " server_ip
        read -p "Please enter password (must match on both servers): " password
        arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni $stability_flag"
    elif [ "$server_choice" == "1" ]; then
        read -p "Please enter password (must match on both servers): " password
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g. 5 for 5:1): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password --noise:$upload_ratio $stability_flag"
        else
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password $stability_flag"
        fi
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
Description=my tunnel service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/RTT $arguments
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl start tunnel.service
    sudo systemctl enable tunnel.service

    # Automatically apply the stability profile right after install
    apply_kernel_tuning

    sleep 2
    if sudo systemctl is-active --quiet tunnel.service; then
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
    read -p "Which server do you want to use? (Enter '1' for Iran/internal-server or '2' for Kharej/external-server): " server_choice
    read -p "Please enter SNI (default: sheypoor.com): " sni
    sni=${sni:-sheypoor.com}

    local stability_flag="--connection-age:4800"

    if [ "$server_choice" == "2" ]; then
        read -p "Is this your main server (VPN server)? (yes/no): " is_main_server
        read -p "Please enter IRAN IP (internal-server): " server_ip
        read -p "Please enter password (must match on both servers): " password

        if [ "$is_main_server" == "yes" ]; then
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni $stability_flag"
        elif [ "$is_main_server" == "no" ]; then
            read -p "Enter your main IP (VPN server): " main_ip
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:$main_ip --toport:multiport --password:$password --sni:$sni $stability_flag"
        else
            echo "Invalid choice for main server. Please enter 'yes' or 'no'."
            exit 1
        fi

    elif [ "$server_choice" == "1" ]; then
        read -p "Please enter password (must match on both servers): " password
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g. 5 for 5:1): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni --noise:$upload_ratio $stability_flag"
        else
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni $stability_flag"
        fi

        num_ips=0
        while true; do
            ((num_ips++))
            read -p "Please enter IP of peer server $num_ips (or type 'done' to finish): " ip

            if [ "$ip" == "done" ]; then
                break
            else
                arguments="$arguments --peer:$ip"
            fi
        done
    else
        echo "Invalid choice. Please enter '1' or '2'."
        exit 1
    fi

    echo "Configured arguments: $arguments"
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
Description=my lbtunnel service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/RTT $arguments
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl start lbtunnel.service
    sudo systemctl enable lbtunnel.service

    apply_kernel_tuning

    sleep 2
    if sudo systemctl is-active --quiet lbtunnel.service; then
        echo -e "${green}Load-balancer service started successfully.${rest}"
    else
        echo -e "${red}Load-balancer service failed to start! Check: journalctl -u lbtunnel.service -n 50${rest}"
    fi
}

lb_uninstall() {
    if [ ! -f "/etc/systemd/system/lbtunnel.service" ]; then
        echo "The Load-balancer is not installed."
        return
    fi

    sudo systemctl stop lbtunnel.service
    sudo systemctl disable lbtunnel.service

    sudo rm -f /etc/systemd/system/lbtunnel.service
    sudo systemctl reset-failed
    sudo rm -f "$INSTALL_DIR/RTT"
    sudo rm -f "$INSTALL_DIR/install.sh" 2>/dev/null

    echo "Uninstallation completed successfully."
}

uninstall() {
    if [ ! -f "/etc/systemd/system/tunnel.service" ]; then
        echo "The service is not installed."
        return
    fi

    sudo systemctl stop tunnel.service
    sudo systemctl disable tunnel.service

    sudo rm -f /etc/systemd/system/tunnel.service
    sudo systemctl reset-failed
    sudo rm -f "$INSTALL_DIR/RTT"
    sudo rm -f "$INSTALL_DIR/install.sh" 2>/dev/null

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
        echo -e "${red}Could not fetch latest version from GitHub API (rate-limited or blocked?).${rest}"
        return 1
    fi

    if version_gt "$latest_version" "$installed_version"; then
        echo "Updating to $latest_version (Installed: $installed_version)..."

        local was_tunnel_active=0
        local was_lb_active=0

        if sudo systemctl is-active --quiet tunnel.service; then
            sudo systemctl stop tunnel.service > /dev/null 2>&1
            was_tunnel_active=1
        fi
        if sudo systemctl is-active --quiet lbtunnel.service; then
            sudo systemctl stop lbtunnel.service > /dev/null 2>&1
            was_lb_active=1
        fi

        if ! wget "https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh" -O install.sh; then
            echo -e "${red}Failed to download install.sh, update aborted.${rest}"
            return 1
        fi
        chmod +x install.sh
        bash install.sh

        [ "$was_tunnel_active" -eq 1 ] && sudo systemctl start tunnel.service
        [ "$was_lb_active" -eq 1 ] && sudo systemctl start lbtunnel.service

        echo "Service updated and restarted successfully."
    else
        echo "You have the latest version ($installed_version)."
    fi
}

compile() {
    detect_distribution
    check_dependencies

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        case "$(uname -m)" in
            x86_64)  file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/linux_x64.tar.xz" ;;
            aarch64) file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/linux_arm64.tar.xz" ;;
            armv7l)  file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/linux_armv7l.tar.xz" ;;
            *) echo "Unknown architecture!"; exit 1 ;;
        esac
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/macosx_x64.tar.xz"
    else
        echo "Unsupported operating system!"
        exit 1
    fi

    cd "$INSTALL_DIR" || exit 1

    if ! wget "$file_url"; then
        echo -e "${red}Failed to download Nim toolchain.${rest}"
        exit 1
    fi
    tar -xvf "$(basename "$file_url")"

    export PATH="$(pwd)/nim-2.0.1/bin:$PATH"

    if ! git clone https://github.com/radkesvat/ReverseTlsTunnel.git; then
        echo -e "${red}Failed to clone repository.${rest}"
        exit 1
    fi

    cd ReverseTlsTunnel || exit 1

    nim install
    nim build

    echo "Project compiled successfully."
    echo "RTT file is located at: $INSTALL_DIR/ReverseTlsTunnel/dist"
}

start_tunnel() {
    if sudo systemctl is-enabled --quiet tunnel.service; then
        sudo systemctl start tunnel.service > /dev/null 2>&1
        if sudo systemctl is-active --quiet tunnel.service; then
            echo "Tunnel service started."
        else
            echo "Tunnel service failed to start."
        fi
    else
        echo "Multiport Tunnel is not installed."
    fi
}

stop_tunnel() {
    if sudo systemctl is-enabled --quiet tunnel.service; then
        sudo systemctl stop tunnel.service > /dev/null 2>&1
        if sudo systemctl is-active --quiet tunnel.service; then
            echo "Tunnel service failed to stop."
        else
            echo "Tunnel service stopped."
        fi
    else
        echo "Multiport Tunnel is not installed."
    fi
}

check_tunnel_status() {
    if sudo systemctl is-active --quiet tunnel.service; then
        echo -e "${yellow}Multiport is: ${green}    [running OK]${rest}"
    else
        echo -e "${yellow}Multiport is:${red}    [Not running]${rest}"
    fi
}

start_lb_tunnel() {
    if sudo systemctl is-enabled --quiet lbtunnel.service; then
        sudo systemctl start lbtunnel.service > /dev/null 2>&1
        if sudo systemctl is-active --quiet lbtunnel.service; then
            echo "Tunnel service started."
        else
            echo "Tunnel service failed to start."
        fi
    else
        echo "Load-Balancer is not installed."
    fi
}

stop_lb_tunnel() {
    if sudo systemctl is-enabled --quiet lbtunnel.service; then
        sudo systemctl stop lbtunnel.service > /dev/null 2>&1
        if sudo systemctl is-active --quiet lbtunnel.service; then
            echo "Load-Balancer failed to stop."
        else
            echo "Load-Balancer stopped."
        fi
    else
        echo "Load-Balancer is not installed."
    fi
}

check_lb_tunnel_status() {
    if sudo systemctl is-active --quiet lbtunnel.service; then
        echo -e "${yellow}Load balancer is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Load balancer is:${red}[Not running]${rest}"
    fi
}

check_c_installed() {
    if [ -f "/etc/systemd/system/custom_tunnel.service" ]; then
        echo "The Custom Tunnel is already installed."
        exit 1
    fi
}

start_c_tunnel() {
    if sudo systemctl is-enabled --quiet custom_tunnel.service; then
        sudo systemctl start custom_tunnel.service > /dev/null 2>&1
        if sudo systemctl is-active --quiet custom_tunnel.service; then
            echo "Custom Tunnel started."
        else
            echo "Custom Tunnel failed to start."
        fi
    else
        echo "Custom Tunnel is not installed."
    fi
}

check_c_tunnel_status() {
    if sudo systemctl is-active --quiet custom_tunnel.service; then
        echo -e "${yellow}Custom Tunnel is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Custom Tunnel is:${red}[Not running]${rest}"
    fi
}

stop_c_tunnel() {
    if sudo systemctl is-enabled --quiet custom_tunnel.service; then
        sudo systemctl stop custom_tunnel.service > /dev/null 2>&1
        if sudo systemctl is-active --quiet custom_tunnel.service; then
            echo "Custom Tunnel failed to stop."
        else
            echo "Custom Tunnel stopped."
        fi
    else
        echo "Custom Tunnel is not installed."
    fi
}

install_custom() {
    root_access
    check_dependencies
    check_c_installed
    install_selected_version

    cd /etc/systemd/system || exit 1
    read -p "Enter RTT arguments (example: RTT --iran --lport:443 --sni:splus.ir --password:123): " arguments

    cat <<EOL > custom_tunnel.service
[Unit]
Description=my custom tunnel service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$arguments
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl start custom_tunnel.service
    sudo systemctl enable custom_tunnel.service

    apply_kernel_tuning
}

c_uninstall() {
    if [ ! -f "/etc/systemd/system/custom_tunnel.service" ]; then
        echo "The Custom Tunnel is not installed."
        return
    fi

    sudo systemctl stop custom_tunnel.service
    sudo systemctl disable custom_tunnel.service

    sudo rm -f /etc/systemd/system/custom_tunnel.service
    sudo systemctl reset-failed
    sudo rm -f "$INSTALL_DIR/RTT"
    sudo rm -f "$INSTALL_DIR/install.sh" 2>/dev/null

    echo "Uninstallation completed successfully."
}

# =========================================================================
# Change the tunnel's SNI in place, without a full reinstall.
# Finds whichever service is installed, edits ExecStart, restarts it.
# Note: SNI must match on both the Iran and Kharej server.
# =========================================================================
change_sni() {
    root_access

    local services=()
    for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
        [ -f "/etc/systemd/system/$svc" ] && services+=("$svc")
    done

    if [ ${#services[@]} -eq 0 ]; then
        echo -e "${red}No RTT service is installed on this server.${rest}"
        return
    fi

    local target_svc
    if [ ${#services[@]} -eq 1 ]; then
        target_svc="${services[0]}"
    else
        echo "Multiple services are installed. Which one do you want to change?"
        select target_svc in "${services[@]}"; do
            [ -n "$target_svc" ] && break
        done
    fi

    local svc_path="/etc/systemd/system/$target_svc"

    if ! grep -q -- "--sni:" "$svc_path"; then
        echo -e "${red}No --sni parameter found in this service (maybe a custom install without SNI).${rest}"
        return
    fi

    local current_sni
    current_sni=$(grep "ExecStart=" "$svc_path" | sed -n 's/.*--sni:\([^ ]*\).*/\1/p')
    echo -e "Current SNI: ${cyan}$current_sni${rest}"
    read -p "Enter the new SNI (e.g. yahoo.com): " new_sni

    if [ -z "$new_sni" ]; then
        echo "Nothing entered, canceled."
        return
    fi

    cp "$svc_path" "${svc_path}.bak.$(date +%s)"
    sed -i "s/--sni:[^ ]*/--sni:$new_sni/" "$svc_path"

    sudo systemctl daemon-reload
    sudo systemctl restart "$target_svc"

    sleep 2
    if sudo systemctl is-active --quiet "$target_svc"; then
        echo -e "${green}SNI successfully changed to '$new_sni' and the service was restarted.${rest}"
        echo -e "${yellow}Remember to make the same change on the peer server (Iran/Kharej) - SNI must match on both sides.${rest}"
    else
        echo -e "${red}Service failed to come up after changing SNI! Check: journalctl -u $target_svc -n 50${rest}"
        echo -e "${yellow}You can restore the backup file (${svc_path}.bak.*) to roll back.${rest}"
    fi
}

# =========================================================================
# Install HAProxy for forwarding arbitrary TCP ports (e.g. internal
# services sitting behind the tunnel) without manually editing
# iptables/socat rules.
# =========================================================================
install_haproxy() {
    root_access
    detect_distribution

    if ! command -v haproxy &> /dev/null; then
        echo -e "${cyan}===> Installing HAProxy...${rest}"
        sudo "${package_manager}" install -y haproxy
    fi

    if ! command -v haproxy &> /dev/null; then
        echo -e "${red}HAProxy installation failed.${rest}"
        return
    fi

    echo -e "${yellow}For each port you want to forward, enter the listen port and the destination.${rest}"
    echo -e "${yellow}Destination example: 127.0.0.1:8080 or another-ip:port${rest}"

    local cfg_entries=""
    local ports_opened=()
    local port_num=0

    while true; do
        ((port_num++))
        read -p "Listen port #$port_num (or 'done' to finish): " listen_port
        [ "$listen_port" == "done" ] && break

        if ! [[ "$listen_port" =~ ^[0-9]+$ ]]; then
            echo "Invalid port, try again."
            ((port_num--))
            continue
        fi

        echo -e "${yellow}Enter one or more backend destinations for port $listen_port.${rest}"
        echo -e "${yellow}If you enter more than one, HAProxy will round-robin between them${rest}"
        echo -e "${yellow}(useful for spreading traffic across multi-SNI tunnel instances).${rest}"

        local backends=()
        local b=0
        while true; do
            ((b++))
            read -p "  Backend #$b (IP:PORT, or 'done' to finish this port): " dest
            [ "$dest" == "done" ] && break
            [ -z "$dest" ] && { ((b--)); continue; }
            backends+=("$dest")
        done

        if [ ${#backends[@]} -eq 0 ]; then
            echo "No backend given, skipping this port."
            ((port_num--))
            continue
        fi

        local balance_line=""
        [ ${#backends[@]} -gt 1 ] && balance_line="    balance roundrobin"

        local server_lines=""
        local sidx=0
        for dest in "${backends[@]}"; do
            ((sidx++))
            server_lines+="    server srv_${listen_port}_${sidx} ${dest} check
"
        done

        cfg_entries+="
frontend front_${listen_port}
    bind *:${listen_port}
    mode tcp
    default_backend back_${listen_port}

backend back_${listen_port}
    mode tcp
${balance_line}
${server_lines}"
        ports_opened+=("$listen_port")
    done

    if [ -z "$cfg_entries" ]; then
        echo "No ports entered, installation canceled."
        return
    fi

    mkdir -p /etc/haproxy
    if [ -f /etc/haproxy/haproxy.cfg ]; then
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date +%s)
    fi

    cat <<EOF > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 8192
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  120s
    timeout server  120s
$cfg_entries
EOF

    if ! haproxy -c -f /etc/haproxy/haproxy.cfg > /dev/null 2>&1; then
        echo -e "${red}HAProxy config has an error:${rest}"
        haproxy -c -f /etc/haproxy/haproxy.cfg
        return
    fi

    # Open the configured ports on the active firewall (firewalld/ufw)
    for p in "${ports_opened[@]}"; do
        if command -v firewall-cmd &> /dev/null && sudo systemctl is-active --quiet firewalld; then
            sudo firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null 2>&1
        fi
        if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
            sudo ufw allow "${p}/tcp" > /dev/null 2>&1
        fi
    done
    command -v firewall-cmd &> /dev/null && sudo firewall-cmd --reload > /dev/null 2>&1

    sudo systemctl daemon-reload
    sudo systemctl enable haproxy > /dev/null 2>&1
    sudo systemctl restart haproxy

    sleep 1
    if sudo systemctl is-active --quiet haproxy; then
        echo -e "${green}HAProxy installed successfully. Forwarded ports:${rest}"
        printf '%s\n' "${ports_opened[@]}"
    else
        echo -e "${red}HAProxy failed to start! Check: journalctl -u haproxy -n 50${rest}"
    fi
}

# =========================================================================
# Multi-SNI mode: runs N parallel, independent RTT tunnel instances
# between the same Iran/Kharej pair, each with its own SNI. Different
# client connections get spread across these tunnels (via HAProxy round
# robin, see below), so overall traffic is not tied to a single SNI
# fingerprint - and if one SNI gets throttled/blocked, the others keep
# working.
#
# Port allocation is computed deterministically from the number of SNIs,
# so as long as you enter the same count and the same SNIs in the same
# order on both servers, the ports line up automatically - no need to
# copy numbers between servers by hand.
# =========================================================================
install_multi_sni() {
    root_access
    check_dependencies

    echo -e "${cyan}This sets up several parallel RTT tunnels, each using a different SNI,${rest}"
    echo -e "${cyan}so overall traffic isn't tied to a single TLS fingerprint.${rest}"
    read -p "Which server is this? (1=Iran, 2=Kharej): " side
    if [[ "$side" != "1" && "$side" != "2" ]]; then
        echo "Invalid choice."
        return
    fi

    read -p "How many SNIs do you want to run in parallel? (default 3): " n_sni
    n_sni=${n_sni:-3}
    if ! [[ "$n_sni" =~ ^[0-9]+$ ]] || [ "$n_sni" -lt 2 ]; then
        echo "Please enter a number >= 2."
        return
    fi

    read -p "Enter the shared password (must be identical on both servers): " password

    local snis=()
    for ((i = 1; i <= n_sni; i++)); do
        read -p "SNI #$i (e.g. site${i}.example.com): " s
        snis+=("$s")
    done

    local iran_ip=""
    if [ "$side" == "2" ]; then
        read -p "Enter IRAN IP (internal-server): " iran_ip
    fi

    # Deterministic port allocation
    local range_start=1000
    local range_end=65000
    local total=$((range_end - range_start + 1))
    local chunk=$((total / n_sni))

    local starts=() ends=() controls=()
    for ((i = 0; i < n_sni; i++)); do
        local s=$((range_start + i * chunk))
        local e
        if [ "$i" -eq "$((n_sni - 1))" ]; then
            e=$range_end
        else
            e=$((s + chunk - 1))
        fi
        starts+=("$s")
        ends+=("$e")
        controls+=("$s")
    done

    echo -e "${cyan}Port allocation (identical on both servers if inputs match):${rest}"
    for ((i = 0; i < n_sni; i++)); do
        echo "  Instance $((i + 1)): SNI=${snis[$i]}  range=${starts[$i]}-${ends[$i]}  control-port=${controls[$i]}"
    done

    for ((i = 0; i < n_sni; i++)); do
        local idx=$((i + 1))
        local svc="multisni-${idx}.service"
        local sni="${snis[$i]}"
        local lrange="${starts[$i]}-${ends[$i]}"
        local cport="${controls[$i]}"
        local arguments

        if [ "$side" == "1" ]; then
            arguments="--iran --lport:$lrange --sni:$sni --password:$password --connection-age:4800"
        else
            arguments="--kharej --iran-ip:$iran_ip --iran-port:$cport --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni --connection-age:4800"
        fi

        cat <<EOL > /etc/systemd/system/$svc
[Unit]
Description=RTT multi-SNI tunnel instance $idx ($sni)
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/RTT $arguments
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL
        sudo systemctl daemon-reload
        sudo systemctl enable "$svc" > /dev/null 2>&1
        sudo systemctl restart "$svc"
    done

    apply_kernel_tuning

    sleep 2
    echo -e "${cyan}===> Status of multi-SNI instances:${rest}"
    for ((i = 1; i <= n_sni; i++)); do
        if sudo systemctl is-active --quiet "multisni-${i}.service"; then
            echo -e "  Instance $i (${snis[$((i - 1))]}): ${green}running${rest}"
        else
            echo -e "  Instance $i (${snis[$((i - 1))]}): ${red}failed - check: journalctl -u multisni-${i}.service -n 50${rest}"
        fi
    done

    if [ "$side" == "1" ]; then
        echo ""
        echo -e "${yellow}To make clients transparently spread across all $n_sni SNIs through a${rest}"
        echo -e "${yellow}single public port, use menu option 20 (Install HAProxy) and, when asked${rest}"
        echo -e "${yellow}for backend destinations, add ALL of the following for the same listen port:${rest}"
        for ((i = 0; i < n_sni; i++)); do
            echo "  - 127.0.0.1:${starts[$i]}"
        done
        echo -e "${yellow}HAProxy will round-robin new connections across them automatically.${rest}"
    fi
}

# ip & version
myip=$(hostname -I | awk '{print $1}')
version=$([ -f "$INSTALL_DIR/RTT" ] && "$INSTALL_DIR/RTT" -v 2>&1 | grep -o 'version="[0-9.]*"')

clear
echo -e "${cyan}Radkesvat Fixed By Parham Pahlean${rest}"
echo -e "Your IP is: ${cyan}($myip)${rest} "
echo -e "${yellow}******************************${rest}"
check_tunnel_status
check_lb_tunnel_status
check_c_tunnel_status
echo -e "${yellow}******************************${rest}"
echo -e " ${purple}--------#- Reverse Tls Tunnel -#--------${rest}"
echo -e "${green}1) Install (Multiport)${rest}"
echo -e "${red}2) Uninstall (Multiport)${rest}"
echo "3) Start Multiport"
echo "4) Stop Multiport"
echo "5) Check Status"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${green}6) Install Load-balancer${rest}"
echo -e "${red}7) Uninstall Load-balancer${rest}"
echo "8) Start Load Balancer"
echo "9) Stop Load Balancer"
echo "10) Check status"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${green}11) Install Custom${rest}"
echo -e "${red}12) Uninstall Custom${rest}"
echo "13) Start Custom"
echo "14) Stop Custom"
echo "15) Check status"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${cyan}16) Update RTT${rest}"
echo -e "${cyan}17) Compile RTT${rest}"
echo -e "${purple}18) Re-apply kernel tuning profile only${rest}"
echo -e "${cyan}19) Change Tunnel SNI (no reinstall)${rest}"
echo -e "${cyan}20) Install HAProxy (port forwarding)${rest}"
echo -e "${purple}21) Setup Multi-SNI parallel tunnels${rest}"
echo "0) Exit"
echo -e "${purple} --------------${cyan}$version${purple}--------------${rest}"
read -p "Please choose: " choice

case $choice in
    1) install ;;
    2) uninstall ;;
    3) start_tunnel ;;
    4) stop_tunnel ;;
    5) check_tunnel_status ;;
    6) load-balancer ;;
    7) lb_uninstall ;;
    8) start_lb_tunnel ;;
    9) stop_lb_tunnel ;;
    10) check_lb_tunnel_status ;;
    11) install_custom ;;
    12) c_uninstall ;;
    13) start_c_tunnel ;;
    14) stop_c_tunnel ;;
    15) check_c_tunnel_status ;;
    16) update_services ;;
    17) compile ;;
    18) root_access; apply_kernel_tuning ;;
    19) change_sni ;;
    20) install_haproxy ;;
    21) install_multi_sni ;;
    0) exit ;;
    *) echo "Invalid choice. Please try again." ;;
esac
