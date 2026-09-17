#!/bin/bash
# =========================================================================
# RTT (ReverseTlsTunnel) Installer - v4
#
# CHANGELOG vs v3 (full audit requested by user):
#   Bug fixes:
#     - All generated systemd units now set StartLimitIntervalSec=0. This
#       was the most important correctness bug in v3: with Restart=always
#       + RestartSec=3, a burst of 5+ crashes in a row (a real scenario on
#       a lossy Iran<->abroad link) would hit systemd's default restart
#       burst limit and the service would silently stop being restarted
#       at all, sitting "failed (start-limit-hit)" until someone noticed
#       and ran `systemctl reset-failed`. This is very likely the cause
#       of the "قطعی های مکرر" (repeated drops that don't come back on
#       their own) some RTT users report.
#     - Every "sudo ..." call is now routed through a $SUDO variable that
#       is empty when already running as root. v3 always shelled out to
#       `sudo`, which is missing by default on some minimal VPS/container
#       images even when logged in as root - on those images every single
#       sudo-based action (start/stop/status/tuning) silently failed with
#       "sudo: command not found".
#     - Cake qdisc availability detection was actually broken: it deleted
#       its own test qdisc from `lo` and then checked for cake in
#       `tc qdisc show`, which will almost never find it again even when
#       cake IS supported (especially when cake is compiled directly into
#       the kernel rather than as a loadable module). Fixed to remember
#       the result of the actual test instead of re-deriving it.
#     - update_services() only stopped/restarted tunnel.service and
#       lbtunnel.service around a binary update; custom_tunnel.service and
#       any multisni-N.service kept running the in-memory old binary and
#       were never restarted onto the new one. Fixed to handle all
#       installed service types.
#     - install_rtt_custom() (custom-version install) refused to run at
#       all if ANY RTT process was running, instead of stopping/restarting
#       the other services the way the "latest version" path already did.
#       Harmonized the two paths.
#     - apply_kernel_tuning()'s LimitNOFILE safety-net loop only checked
#       tunnel/lbtunnel/custom_tunnel, not multisni-N services. Extended.
#     - Added basic input validation: a password, SNI or IP containing a
#       space silently breaks the generated ExecStart line (systemd splits
#       it on whitespace), producing a service that starts with wrong
#       arguments and no obvious error. Now rejected up front.
#     - Distro detection now also recognizes rocky/almalinux/rhel (treated
#       like centos) instead of hard-exiting as "unsupported".
#     - CentOS-family installs now attempt to enable epel-release first,
#       since mtr/haproxy are unreliable to install without it there.
#
#   Stability / stability-related additions:
#     - New: an optional connection watchdog (see install_watchdog),
#       installed automatically at the end of every install path on BOTH
#       the Iran server and the Kharej server. It runs every 15s via a
#       systemd timer and: restarts a crashed service immediately,
#       restarts a service that is "active" but not actually listening
#       (a hung process), and on the Kharej side, restarts a tunnel that
#       has lost all connectivity to the Iran server for several checks
#       in a row (sustained packet loss / dead path) or that has had zero
#       established connections to the Iran server for a while despite
#       being "active". Restarts are rate-limited per service so a truly
#       dead upstream path cannot cause a restart storm.
#     - Added an optional --keep-ufw prompt: RTT disables UFW on startup
#       by default (undocumented side effect for anyone relying on UFW),
#       so the installer now asks and, if you opt to keep UFW, also opens
#       the tunnel's own port range on it automatically.
#     - configure_bandwidth_shaping() no longer passes the "nat" cake
#       keyword, which only makes sense on a NAT gateway shaping multiple
#       internal hosts - this box is the tunnel endpoint itself.
#
#   NOTE: radkesvat/ReverseTlsTunnel was archived by its author on
#   2025-08-16 ("این پروژه دیگه آپدیت نمیشه"). update_services() will
#   still fetch whatever the last published release is, but no new
#   upstream releases are expected.
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

# Route every privileged call through $SUDO instead of a hardcoded "sudo".
# When we are already root (the normal case, since root_access() enforces
# it before any real action), SUDO is empty so we never depend on a sudo
# binary that may not exist on minimal images.
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

# Returns 0 (true) if any RTT-based service OTHER than the ones passed as
# arguments is still installed. Used to avoid deleting the shared
# $INSTALL_DIR/RTT binary while some other running service still needs it.
other_rtt_services_installed() {
    local exclude=("$@")
    local all_services=(tunnel.service lbtunnel.service custom_tunnel.service)
    # include any multisni-N.service files present
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

# Reject a value that contains whitespace: it would silently break the
# generated ExecStart= line, since systemd tokenizes on whitespace.
validate_no_space() {
    local val="$1" label="$2"
    if [[ "$val" == *" "* ]]; then
        echo -e "${red}Error: $label cannot contain spaces (systemd would split the command line on it and RTT would get the wrong arguments). Please run this again without spaces.${rest}"
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

    # RHEL-family images frequently need EPEL for mtr/haproxy to resolve.
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

    # CentOS/Fedora usually run firewalld; RTT itself only disables ufw.
    if command -v firewall-cmd &> /dev/null && $SUDO systemctl is-active --quiet firewalld; then
        echo -e "${yellow}firewalld detected and active. Opening 23-65535/tcp...${rest}"
        $SUDO firewall-cmd --permanent --add-port=23-65535/tcp > /dev/null 2>&1
        $SUDO firewall-cmd --reload > /dev/null 2>&1
    fi
}

# RTT disables UFW on startup by default. Ask once, and if the person
# wants to keep it, open the tunnel's own port range on it.
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
    # $1 = "start-end" or a single port
    if [ -n "$KEEP_UFW_FLAG" ]; then
        $SUDO ufw allow "${1}/tcp" > /dev/null 2>&1
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

    $SUDO sysctl --system > /dev/null 2>&1

    if ! $SUDO sysctl -w fs.file-max=2097152 > /dev/null 2>&1; then
        echo -e "${yellow}Could not raise fs.file-max (likely a restricted container). If RTT logs${rest}"
        echo -e "${yellow}\"Could not increase system max connection\" or a file-descriptor error,${rest}"
        echo -e "${yellow}add --keep-os-limit to its arguments (menu options 19/change_sni won't do${rest}"
        echo -e "${yellow}this for you, edit the service's ExecStart manually).${rest}"
    fi

    # LimitNOFILE on all installed RTT services (regular + multi-SNI)
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
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable rtt-mss-clamp.service > /dev/null 2>&1
    $SUDO systemctl start rtt-mss-clamp.service

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

    # Self-heal: if RTT processes are running but the binary file no
    # longer exists on disk (e.g. a previous uninstall removed the
    # shared binary while other services still referenced it), those
    # are orphaned/zombie processes referencing a deleted inode. Kill
    # them so the fresh install isn't blocked and can proceed cleanly.
    if pgrep -x "RTT" > /dev/null && [ ! -f "$INSTALL_DIR/RTT" ]; then
        echo -e "${yellow}Detected orphaned RTT process(es) referencing a missing binary. Cleaning up...${rest}"
        pkill -x RTT 2>/dev/null
        sleep 1
    fi

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

    restart_all_rtt_services
}

# Restart every currently-installed RTT service (tunnel/lb/custom/multi-sni)
# so they all pick up a freshly (re)placed binary instead of continuing to
# run on a stale in-memory copy. Shared by install_rtt(), install_rtt_custom()
# and update_services() so all three code paths behave the same way.
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
        echo -e "${yellow}Stopping running RTT service(s) before swapping the binary...${rest}"
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

    if [ "$was_running" -eq 1 ]; then
        restart_all_rtt_services
        echo "Binary updated and previously-running services restarted."
    else
        echo "Finished."
    fi
}

configure_arguments() {
    read -p "Which server do you want to use? (Enter '1' for Iran/internal-server or '2' for Kharej/external-server): " server_choice
    read -p "Please enter SNI (default: sheypoor.com): " sni
    sni=${sni:-sheypoor.com}
    validate_no_space "$sni" "SNI"

    prompt_keep_ufw

    # --connection-age is used instead of the deprecated/unrecognized
    # --terminate flag, which can cause the binary to error out and get
    # stuck in a systemd restart loop on current releases.
    local stability_flag="--connection-age:4800"

    if [ "$server_choice" == "2" ]; then
        read -p "Please enter IRAN IP (internal-server): " server_ip
        validate_no_space "$server_ip" "IRAN IP"
        read -p "Please enter password (must match on both servers): " password
        validate_no_space "$password" "password"
        arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni $stability_flag$KEEP_UFW_FLAG"
    elif [ "$server_choice" == "1" ]; then
        read -p "Please enter password (must match on both servers): " password
        validate_no_space "$password" "password"
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g. 5 for 5:1): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password --noise:$upload_ratio $stability_flag$KEEP_UFW_FLAG"
        else
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password $stability_flag$KEEP_UFW_FLAG"
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
Description=my tunnel service
After=network.target
StartLimitIntervalSec=0

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

    $SUDO systemctl daemon-reload
    $SUDO systemctl start tunnel.service
    $SUDO systemctl enable tunnel.service

    # Automatically apply the stability profile right after install
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
    read -p "Which server do you want to use? (Enter '1' for Iran/internal-server or '2' for Kharej/external-server): " server_choice
    read -p "Please enter SNI (default: sheypoor.com): " sni
    sni=${sni:-sheypoor.com}
    validate_no_space "$sni" "SNI"

    prompt_keep_ufw

    local stability_flag="--connection-age:4800"

    if [ "$server_choice" == "2" ]; then
        read -p "Is this your main server (VPN server)? (yes/no): " is_main_server
        read -p "Please enter IRAN IP (internal-server): " server_ip
        validate_no_space "$server_ip" "IRAN IP"
        read -p "Please enter password (must match on both servers): " password
        validate_no_space "$password" "password"

        if [ "$is_main_server" == "yes" ]; then
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni $stability_flag$KEEP_UFW_FLAG"
        elif [ "$is_main_server" == "no" ]; then
            read -p "Enter your main IP (VPN server): " main_ip
            validate_no_space "$main_ip" "main IP"
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:$main_ip --toport:multiport --password:$password --sni:$sni $stability_flag$KEEP_UFW_FLAG"
        else
            echo "Invalid choice for main server. Please enter 'yes' or 'no'."
            exit 1
        fi

    elif [ "$server_choice" == "1" ]; then
        read -p "Please enter password (must match on both servers): " password
        validate_no_space "$password" "password"
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g. 5 for 5:1): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni --noise:$upload_ratio $stability_flag$KEEP_UFW_FLAG"
        else
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni $stability_flag$KEEP_UFW_FLAG"
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
StartLimitIntervalSec=0

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

    $SUDO systemctl daemon-reload
    $SUDO systemctl start lbtunnel.service
    $SUDO systemctl enable lbtunnel.service

    apply_kernel_tuning
    install_watchdog

    sleep 2
    if $SUDO systemctl is-active --quiet lbtunnel.service; then
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

    $SUDO systemctl stop lbtunnel.service
    $SUDO systemctl disable lbtunnel.service

    $SUDO rm -f /etc/systemd/system/lbtunnel.service
    $SUDO systemctl reset-failed
    if other_rtt_services_installed "lbtunnel.service"; then
        echo -e "${yellow}Other RTT services are still installed - keeping the shared RTT binary.${rest}"
    else
        $SUDO rm -f "$INSTALL_DIR/RTT"
        $SUDO rm -f "$INSTALL_DIR/install.sh" 2>/dev/null
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
    if other_rtt_services_installed "tunnel.service"; then
        echo -e "${yellow}Other RTT services are still installed - keeping the shared RTT binary.${rest}"
    else
        $SUDO rm -f "$INSTALL_DIR/RTT"
        $SUDO rm -f "$INSTALL_DIR/install.sh" 2>/dev/null
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
        echo -e "${red}Could not fetch latest version from GitHub API (rate-limited, blocked, or the repo has no releases reachable this way).${rest}"
        return 1
    fi

    if version_gt "$latest_version" "$installed_version"; then
        echo "Updating to $latest_version (Installed: $installed_version)..."
        echo -e "${yellow}Note: this upstream project was archived by its author, so this is likely${rest}"
        echo -e "${yellow}the last release that will ever appear here.${rest}"

        # Stop every installed RTT service (not just tunnel/lbtunnel) so
        # none of them keep running the old in-memory binary afterwards.
        local stopped=()
        for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
            if [ -f "/etc/systemd/system/$svc" ] && $SUDO systemctl is-active --quiet "$svc"; then
                $SUDO systemctl stop "$svc" > /dev/null 2>&1
                stopped+=("$svc")
            fi
        done
        for f in /etc/systemd/system/multisni-*.service; do
            [ -e "$f" ] || continue
            local svc
            svc="$(basename "$f")"
            if $SUDO systemctl is-active --quiet "$svc"; then
                $SUDO systemctl stop "$svc" > /dev/null 2>&1
                stopped+=("$svc")
            fi
        done

        if ! wget "https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh" -O install.sh; then
            echo -e "${red}Failed to download install.sh, update aborted.${rest}"
            for svc in "${stopped[@]}"; do $SUDO systemctl start "$svc" > /dev/null 2>&1; done
            return 1
        fi
        chmod +x install.sh
        bash install.sh

        for svc in "${stopped[@]}"; do
            $SUDO systemctl start "$svc" > /dev/null 2>&1
        done

        echo "Service(s) updated and restarted successfully."
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
    if $SUDO systemctl is-enabled --quiet tunnel.service; then
        $SUDO systemctl start tunnel.service > /dev/null 2>&1
        if $SUDO systemctl is-active --quiet tunnel.service; then
            echo "Tunnel service started."
        else
            echo "Tunnel service failed to start."
        fi
    else
        echo "Multiport Tunnel is not installed."
    fi
}

stop_tunnel() {
    if $SUDO systemctl is-enabled --quiet tunnel.service; then
        $SUDO systemctl stop tunnel.service > /dev/null 2>&1
        if $SUDO systemctl is-active --quiet tunnel.service; then
            echo "Tunnel service failed to stop."
        else
            echo "Tunnel service stopped."
        fi
    else
        echo "Multiport Tunnel is not installed."
    fi
}

check_tunnel_status() {
    if $SUDO systemctl is-active --quiet tunnel.service; then
        echo -e "${yellow}Multiport is: ${green}    [running OK]${rest}"
    else
        echo -e "${yellow}Multiport is:${red}    [Not running]${rest}"
    fi
}

start_lb_tunnel() {
    if $SUDO systemctl is-enabled --quiet lbtunnel.service; then
        $SUDO systemctl start lbtunnel.service > /dev/null 2>&1
        if $SUDO systemctl is-active --quiet lbtunnel.service; then
            echo "Tunnel service started."
        else
            echo "Tunnel service failed to start."
        fi
    else
        echo "Load-Balancer is not installed."
    fi
}

stop_lb_tunnel() {
    if $SUDO systemctl is-enabled --quiet lbtunnel.service; then
        $SUDO systemctl stop lbtunnel.service > /dev/null 2>&1
        if $SUDO systemctl is-active --quiet lbtunnel.service; then
            echo "Load-Balancer failed to stop."
        else
            echo "Load-Balancer stopped."
        fi
    else
        echo "Load-Balancer is not installed."
    fi
}

check_lb_tunnel_status() {
    if $SUDO systemctl is-active --quiet lbtunnel.service; then
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
    if $SUDO systemctl is-enabled --quiet custom_tunnel.service; then
        $SUDO systemctl start custom_tunnel.service > /dev/null 2>&1
        if $SUDO systemctl is-active --quiet custom_tunnel.service; then
            echo "Custom Tunnel started."
        else
            echo "Custom Tunnel failed to start."
        fi
    else
        echo "Custom Tunnel is not installed."
    fi
}

check_c_tunnel_status() {
    if $SUDO systemctl is-active --quiet custom_tunnel.service; then
        echo -e "${yellow}Custom Tunnel is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Custom Tunnel is:${red}[Not running]${rest}"
    fi
}

stop_c_tunnel() {
    if $SUDO systemctl is-enabled --quiet custom_tunnel.service; then
        $SUDO systemctl stop custom_tunnel.service > /dev/null 2>&1
        if $SUDO systemctl is-active --quiet custom_tunnel.service; then
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
    echo -e "${yellow}Tip: you can add --keep-ufw (don't disable UFW) or --keep-os-limit (if this${rest}"
    echo -e "${yellow}box can't raise its file-descriptor limit, e.g. some containers) to the${rest}"
    echo -e "${yellow}arguments below if you need them.${rest}"
    read -p "Enter RTT arguments (example: RTT --iran --lport:443 --sni:splus.ir --password:123): " arguments

    cat <<EOL > custom_tunnel.service
[Unit]
Description=my custom tunnel service
After=network.target
StartLimitIntervalSec=0

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

    $SUDO systemctl daemon-reload
    $SUDO systemctl start custom_tunnel.service
    $SUDO systemctl enable custom_tunnel.service

    apply_kernel_tuning
    install_watchdog
}

c_uninstall() {
    if [ ! -f "/etc/systemd/system/custom_tunnel.service" ]; then
        echo "The Custom Tunnel is not installed."
        return
    fi

    $SUDO systemctl stop custom_tunnel.service
    $SUDO systemctl disable custom_tunnel.service

    $SUDO rm -f /etc/systemd/system/custom_tunnel.service
    $SUDO systemctl reset-failed
    if other_rtt_services_installed "custom_tunnel.service"; then
        echo -e "${yellow}Other RTT services are still installed - keeping the shared RTT binary.${rest}"
    else
        $SUDO rm -f "$INSTALL_DIR/RTT"
        $SUDO rm -f "$INSTALL_DIR/install.sh" 2>/dev/null
    fi

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
    for f in /etc/systemd/system/multisni-*.service; do
        [ -e "$f" ] && services+=("$(basename "$f")")
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
    validate_no_space "$new_sni" "SNI"

    if [ -z "$new_sni" ]; then
        echo "Nothing entered, canceled."
        return
    fi

    cp "$svc_path" "${svc_path}.bak.$(date +%s)"
    sed -i "s/--sni:[^ ]*/--sni:$new_sni/" "$svc_path"

    $SUDO systemctl daemon-reload
    $SUDO systemctl restart "$target_svc"

    sleep 2
    if $SUDO systemctl is-active --quiet "$target_svc"; then
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
        $SUDO "${package_manager}" install -y haproxy
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
    retries 3
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
        if command -v firewall-cmd &> /dev/null && $SUDO systemctl is-active --quiet firewalld; then
            $SUDO firewall-cmd --permanent --add-port="${p}/tcp" > /dev/null 2>&1
        fi
        if command -v ufw &> /dev/null && $SUDO ufw status | grep -q "Status: active"; then
            $SUDO ufw allow "${p}/tcp" > /dev/null 2>&1
        fi
    done
    command -v firewall-cmd &> /dev/null && $SUDO firewall-cmd --reload > /dev/null 2>&1

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable haproxy > /dev/null 2>&1
    $SUDO systemctl restart haproxy

    sleep 1
    if $SUDO systemctl is-active --quiet haproxy; then
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
    validate_no_space "$password" "password"

    prompt_keep_ufw

    local snis=()
    for ((i = 1; i <= n_sni; i++)); do
        read -p "SNI #$i (e.g. site${i}.example.com): " s
        validate_no_space "$s" "SNI #$i"
        snis+=("$s")
    done

    local iran_ip=""
    if [ "$side" == "2" ]; then
        read -p "Enter IRAN IP (internal-server): " iran_ip
        validate_no_space "$iran_ip" "IRAN IP"
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
            arguments="--iran --lport:$lrange --sni:$sni --password:$password --connection-age:4800$KEEP_UFW_FLAG"
            open_ufw_range "${starts[$i]}:${ends[$i]}"
        else
            arguments="--kharej --iran-ip:$iran_ip --iran-port:$cport --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni --connection-age:4800$KEEP_UFW_FLAG"
        fi

        cat <<EOL > /etc/systemd/system/$svc
[Unit]
Description=RTT multi-SNI tunnel instance $idx ($sni)
After=network.target
StartLimitIntervalSec=0

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
        $SUDO systemctl daemon-reload
        $SUDO systemctl enable "$svc" > /dev/null 2>&1
        $SUDO systemctl restart "$svc"
    done

    apply_kernel_tuning
    install_watchdog

    sleep 2
    echo -e "${cyan}===> Status of multi-SNI instances:${rest}"
    for ((i = 1; i <= n_sni; i++)); do
        if $SUDO systemctl is-active --quiet "multisni-${i}.service"; then
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

# =========================================================================
# Optional extra layer: Cake queue discipline with explicit bandwidth
# shaping. This targets LOCAL bufferbloat/jitter (queueing on this
# server's own network interface under load), which is a different
# problem from backbone-level jitter/reordering further out on the
# path (which no server-side setting can fix). Cake needs to know the
# real uplink speed to shape effectively, so it's a separate opt-in
# step rather than something applied blindly by default.
# =========================================================================
configure_bandwidth_shaping() {
    root_access

    # Test cake support directly and remember the result - don't re-derive
    # it later from `tc qdisc show`, since we're about to remove our own
    # test qdisc and that check would then almost always come back empty
    # even when cake genuinely is available (e.g. compiled in, not a
    # loadable module).
    local cake_available=0
    if tc qdisc add dev lo root cake 2>/dev/null; then
        cake_available=1
        tc qdisc del dev lo root 2>/dev/null
    else
        modprobe sch_cake 2>/dev/null
        if tc qdisc add dev lo root cake 2>/dev/null; then
            cake_available=1
            tc qdisc del dev lo root 2>/dev/null
        fi
    fi

    if [ "$cake_available" -eq 0 ]; then
        echo -e "${red}The 'cake' qdisc is not available on this kernel. Skipping.${rest}"
        echo -e "${yellow}(Usually available on kernel 4.19+ / most current Ubuntu, Debian 11+, CentOS Stream.)${rest}"
        return
    fi

    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$iface" ]; then
        echo -e "${red}Could not detect the default network interface.${rest}"
        return
    fi

    echo -e "${cyan}Enter this server's real, sustained uplink bandwidth (not the burst/marketing number).${rest}"
    echo -e "${cyan}If unsure, run a speed test first and use the upload result.${rest}"
    read -p "Uplink bandwidth in Mbit/s (e.g. 500): " uplink_mbit

    if ! [[ "$uplink_mbit" =~ ^[0-9]+$ ]] || [ "$uplink_mbit" -le 0 ]; then
        echo "Invalid value."
        return
    fi

    # Shape to ~95% of the real link speed: this makes THIS server's own
    # qdisc the bottleneck (where active queue management can act)
    # instead of some upstream/ISP queue with no AQM, which is a very
    # common hidden source of jitter under load.
    local shaped_mbit=$((uplink_mbit * 95 / 100))
    [ "$shaped_mbit" -lt 1 ] && shaped_mbit=1

    tc qdisc del dev "$iface" root 2>/dev/null
    # No "nat": that keyword is for a NAT gateway shaping multiple
    # internal hosts by their pre/post-NAT address via conntrack. This
    # box is the tunnel endpoint itself, not a NAT router, so plain
    # per-flow/per-host fairness is what applies here.
    if tc qdisc replace dev "$iface" root cake bandwidth "${shaped_mbit}mbit" dual-srchost 2>/dev/null; then
        echo -e "${green}Cake shaping applied on $iface at ${shaped_mbit}mbit (95% of ${uplink_mbit}mbit).${rest}"
    else
        echo -e "${red}Failed to apply cake qdisc on $iface.${rest}"
        return
    fi

    # Persist across reboot with a small oneshot systemd unit
    cat <<EOF > /usr/local/sbin/rtt-cake-shaping.sh
#!/bin/bash
IFACE=\$(ip route | grep default | awk '{print \$5}' | head -n1)
[ -n "\$IFACE" ] && tc qdisc replace dev "\$IFACE" root cake bandwidth ${shaped_mbit}mbit dual-srchost
EOF
    chmod +x /usr/local/sbin/rtt-cake-shaping.sh

    cat <<EOF > /etc/systemd/system/rtt-cake-shaping.service
[Unit]
Description=RTT tunnel Cake bandwidth shaping (persists across reboot)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rtt-cake-shaping.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable rtt-cake-shaping.service > /dev/null 2>&1

    echo -e "${yellow}Note: this reduces jitter caused by local queueing under load. It cannot${rest}"
    echo -e "${yellow}fix jitter/reordering that occurs further out on the backbone path.${rest}"
}

# =========================================================================
# Uninstall all multi-SNI instances (multisni-N.service). The shared RTT
# binary is only removed if no other RTT service still depends on it.
# =========================================================================
uninstall_multi_sni() {
    root_access

    local found=0
    for f in /etc/systemd/system/multisni-*.service; do
        [ -e "$f" ] || continue
        found=1
        local svc
        svc=$(basename "$f")
        $SUDO systemctl stop "$svc" 2>/dev/null
        $SUDO systemctl disable "$svc" 2>/dev/null
        $SUDO rm -f "/etc/systemd/system/$svc"
        echo "Removed $svc"
    done

    if [ "$found" -eq 0 ]; then
        echo "No multi-SNI instances are installed."
        return
    fi

    $SUDO systemctl reset-failed

    if other_rtt_services_installed; then
        echo -e "${yellow}Other RTT services are still installed - keeping the shared RTT binary.${rest}"
    else
        $SUDO rm -f "$INSTALL_DIR/RTT"
        $SUDO rm -f "$INSTALL_DIR/install.sh" 2>/dev/null
    fi

    echo "Multi-SNI uninstallation completed successfully."
}

# =========================================================================
# Connection watchdog: installed automatically on both the Iran server
# and the Kharej server at the end of every install path (options 1, 6,
# 11, 21), and available standalone via the menu.
#
# Runs every 15s via a systemd timer. Each run:
#   - restarts any installed RTT service that is not "active" at all
#     (crashed) - immediate recovery instead of waiting on the user;
#   - restarts a service that IS "active" per systemd but isn't actually
#     listening on its configured port (a hung/zombie process);
#   - on the Kharej side, tracks pings to the configured iran-ip and, if
#     several checks in a row get no response, restarts that instance -
#     this catches a link that is technically "up" but has gone dead or
#     is dropping essentially all packets, where a fresh reconnect
#     attempt is often what actually recovers it;
#   - on the Kharej side, also tracks whether the service has ANY
#     established TCP connection toward the Iran server; if it has had
#     none for a while despite being "active", treats it the same way.
# Restarts of the SAME service are rate-limited (45s) so a genuinely
# dead upstream path cannot turn into a restart storm.
# =========================================================================
install_watchdog() {
    root_access
    echo -e "${cyan}===> Installing the connection watchdog (fast crash/hang/packet-loss recovery)...${rest}"

    mkdir -p /var/lib/rtt-watchdog

    cat <<'WDEOF' > /usr/local/sbin/rtt-watchdog.sh
#!/bin/bash
# RTT connection watchdog - see install_watchdog() in the installer for
# the full explanation of what this checks and why.

STATE_DIR="/var/lib/rtt-watchdog"
mkdir -p "$STATE_DIR"

log() {
    logger -t rtt-watchdog -- "$1"
}

# Minimum seconds between two restarts of the SAME service, so a
# genuinely dead upstream path can't trigger a restart storm.
MIN_RESTART_GAP=45

# How many consecutive failed checks before we treat something as real
# and act on it (each watchdog run is one sample, runs every ~15s).
LOSS_STREAK_THRESHOLD=3
NOCONN_STREAK_THRESHOLD=6

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
            log "$svc: needs restart ($reason) but last restart was ${diff}s ago - waiting to avoid a restart loop."
            return
        fi
    fi

    log "$svc: restarting - $reason"
    systemctl reset-failed "$svc" 2>/dev/null
    systemctl restart "$svc" 2>/dev/null
    echo "$now" > "$last_file"
}

extract_arg() {
    local svc_path="$1" flag="$2"
    grep "ExecStart=" "$svc_path" | sed -n "s/.*${flag}:\([^ ]*\).*/\1/p"
}

is_kharej_service() {
    grep -q -- "--kharej" "$1"
}

any_port_listening() {
    local lport_spec="$1"
    local first_port="${lport_spec%%-*}"
    [ -z "$first_port" ] && return 1
    ss -H -ltn "( sport = :$first_port )" 2>/dev/null | grep -q LISTEN
}

check_service() {
    local svc="$1"
    local svc_path="/etc/systemd/system/$svc"
    [ -f "$svc_path" ] || return

    systemctl is-enabled --quiet "$svc" 2>/dev/null || return

    if ! systemctl is-active --quiet "$svc"; then
        restart_service "$svc" "service is not active"
        return
    fi

    if is_kharej_service "$svc_path"; then
        local iran_ip iran_port
        iran_ip=$(extract_arg "$svc_path" "--iran-ip")
        iran_port=$(extract_arg "$svc_path" "--iran-port")

        if [ -n "$iran_ip" ]; then
            local streak_file="$STATE_DIR/${svc}.loss_streak"
            if ping -c 1 -W 2 "$iran_ip" > /dev/null 2>&1; then
                echo 0 > "$streak_file"
            else
                local streak
                streak=$(cat "$streak_file" 2>/dev/null || echo 0)
                streak=$((streak + 1))
                echo "$streak" > "$streak_file"
                if [ "$streak" -ge "$LOSS_STREAK_THRESHOLD" ]; then
                    restart_service "$svc" "no response from iran-ip ($iran_ip) for $streak checks in a row"
                    echo 0 > "$streak_file"
                    return
                fi
            fi
        fi

        if [ -n "$iran_port" ]; then
            local est noconn_file
            est=$(ss -H -tn state established "( dport = :$iran_port )" 2>/dev/null | wc -l)
            noconn_file="$STATE_DIR/${svc}.noconn_streak"
            if [ "$est" -gt 0 ]; then
                echo 0 > "$noconn_file"
            else
                local ns
                ns=$(cat "$noconn_file" 2>/dev/null || echo 0)
                ns=$((ns + 1))
                echo "$ns" > "$noconn_file"
                if [ "$ns" -ge "$NOCONN_STREAK_THRESHOLD" ]; then
                    restart_service "$svc" "no established connection to the Iran server for a while"
                    echo 0 > "$noconn_file"
                fi
            fi
        fi
    else
        local lport
        lport=$(extract_arg "$svc_path" "--lport")
        if [ -n "$lport" ] && ! any_port_listening "$lport"; then
            restart_service "$svc" "process is running but not listening on its configured port"
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
Description=RTT tunnel watchdog (one-shot health check)
After=network.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

    cat <<EOF > "$WATCHDOG_TIMER"
[Unit]
Description=Run the RTT tunnel watchdog periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now rtt-watchdog.timer > /dev/null 2>&1

    if $SUDO systemctl is-active --quiet rtt-watchdog.timer; then
        echo -e "${green}Watchdog installed and running (checks every 15s).${rest}"
    else
        echo -e "${red}Watchdog timer failed to start! Check: journalctl -u rtt-watchdog.timer -n 50${rest}"
    fi
}

uninstall_watchdog() {
    root_access
    $SUDO systemctl disable --now rtt-watchdog.timer 2>/dev/null
    $SUDO systemctl stop rtt-watchdog.service 2>/dev/null
    $SUDO rm -f "$WATCHDOG_TIMER" "$WATCHDOG_SERVICE" "$WATCHDOG_SCRIPT"
    $SUDO systemctl daemon-reload
    $SUDO systemctl reset-failed 2>/dev/null
    echo "Watchdog removed."
}

show_watchdog_log() {
    if [ ! -f "$WATCHDOG_SCRIPT" ]; then
        echo "Watchdog is not installed."
        return
    fi
    journalctl -t rtt-watchdog -n 100 --no-pager
}

check_watchdog_status() {
    if $SUDO systemctl is-active --quiet rtt-watchdog.timer 2>/dev/null; then
        echo -e "${yellow}Watchdog is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Watchdog is:${red}    [Not installed/running]${rest}"
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
check_watchdog_status
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
echo -e "${purple}22) Configure Cake bandwidth shaping (jitter reduction)${rest}"
echo -e "${red}23) Uninstall Multi-SNI instances${rest}"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${green}24) Install/reinstall connection watchdog${rest}"
echo -e "${cyan}25) Show watchdog log${rest}"
echo -e "${red}26) Uninstall watchdog${rest}"
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
    22) configure_bandwidth_shaping ;;
    23) uninstall_multi_sni ;;
    24) install_watchdog ;;
    25) show_watchdog_log ;;
    26) uninstall_watchdog ;;
    0) exit ;;
    *) echo "Invalid choice. Please try again." ;;
esac
