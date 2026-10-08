#!/bin/bash
# =========================================================================
# RTT (ReverseTlsTunnel) Installer - v5.0 (Anti-Drop & Stability release)
# =========================================================================
# Goal: a fast, light and stable Iran <-> Kharej tunnel without random drops.
#
#  v5.0 changes
#   * --connection-age:4800 on BOTH sides. This is the RTT author's own switch
#     for the random disconnects seen on RTT > 5.4. Menu 8 / 22 add it to an
#     existing install without reinstalling (auto-rollback if rejected).
#   * Kernel profile v2: faster dead-connection detection (tcp_retries2), MTU
#     probing, sane buffers, conntrack sizing on the Iran side, re-applied at
#     every boot.
#   * MSS clamp skips loopback (Kharej -> 127.0.0.1 keeps its big MSS) and is
#     re-applied by the watchdog if something flushes iptables.
#   * Watchdog v5: honours "Stop" from the menu, leaves a service alone while
#     systemd is restarting it, no false D-state / listener alarms, restarts a
#     Kharej that had NO live link to Iran for 5 minutes in a row.
#   * New menu: 8 apply-all-fixes, 9 diagnose, 10 logs, 20/21 change password
#     / IRAN IP, 22 connection-age.
#   * Installer hardening: download timeouts, reuse a local binary when GitHub
#     is blocked, input validation, SSH-port / port-443 / SNI-DNS pre-checks,
#     rollback when a change makes the service fail.
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
UNIT_DIR="/etc/systemd/system"
TUNNEL_MSS=1340
CONN_AGE=4800
RTT_INSTALLER_URL="https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh"
RTT_LATEST_API="https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest"

STATE_DIR="/var/lib/rtt-watchdog"
BACKUP_DIR="$STATE_DIR/backup"
MANUAL_DIR="/run/rtt-watchdog"          # "stopped on purpose" markers (cleared at boot)
SYSCTL_FILE="/etc/sysctl.d/99-rtt-tunnel-tuning.conf"
MODULES_FILE="/etc/modules-load.d/rtt-tunnel.conf"
CT_MAX_PATH="/proc/sys/net/netfilter/nf_conntrack_max"
MSS_CLAMP_SCRIPT="/usr/local/sbin/rtt-mss-clamp.sh"
MSS_CLAMP_SERVICE="$UNIT_DIR/rtt-mss-clamp.service"
WATCHDOG_SCRIPT="/usr/local/sbin/rtt-watchdog.sh"
WATCHDOG_SERVICE="$UNIT_DIR/rtt-watchdog.service"
WATCHDOG_TIMER="$UNIT_DIR/rtt-watchdog.timer"

KEEP_UFW_FLAG=""
KEEP_OS_LIMIT_FLAG=""
CONN_AGE_FLAG=""
LPORT_RANGE="23-65535"
REPLY_VALUE=""
PASS_HINT="Password must not contain spaces or any of: \$ % \\ ' \" \` ; | & < > ( ) { } * ?"

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

# ------------------------------------------------------------------ helpers
list_rtt_services() {
    local svc f
    for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
        [ -f "$UNIT_DIR/$svc" ] && echo "$svc"
    done
    for f in "$UNIT_DIR"/multisni-*.service; do
        [ -e "$f" ] && basename "$f"
    done
    return 0
}

other_rtt_services_installed() {
    local ex svc skip
    while read -r svc; do
        [ -n "$svc" ] || continue
        skip=0
        for ex in "$@"; do
            [ "$svc" == "$ex" ] && skip=1
        done
        [ "$skip" -eq 0 ] && return 0
    done < <(list_rtt_services)
    return 1
}

exec_line_of() { grep -m1 '^ExecStart=' "$UNIT_DIR/$1" 2>/dev/null; }

# exec_arg <unit> <--option>  ->  value of --option:value in the ExecStart line
exec_arg() { exec_line_of "$1" | tr ' ' '\n' | sed -n "s/^$2://p" | head -n1; }

service_role() {
    local l
    l=$(exec_line_of "$1")
    if   [[ "$l" == *" --kharej"* ]]; then echo kharej
    elif [[ "$l" == *" --iran"*   ]]; then echo iran
    else echo other
    fi
}

# portable (no "systemctl show --value": missing on old systemd)
service_pid() {
    local p
    p=$(systemctl show -p MainPID "$1" 2>/dev/null | cut -d= -f2)
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    echo "$p"
}

# true when the SAME pid is still alive ~8s after (re)start => no crash loop
service_stable() {
    local p1 p2
    sleep 3; p1=$(service_pid "$1")
    sleep 5; p2=$(service_pid "$1")
    [ "$p1" -gt 0 ] && [ "$p1" = "$p2" ] && kill -0 "$p2" 2>/dev/null
}

mask_args() { sed -E 's/(--password:)[^ ]+/\1********/g'; }

rtt_version() {
    [ -x "$INSTALL_DIR/RTT" ] || return 0
    "$INSTALL_DIR/RTT" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

version_gt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# listening_ok <pid>  : does this pid own a listening TCP socket?
listening_ok() { ss -tlnp 2>/dev/null | grep -q "pid=${1},"; }

# count_links <pid> <ipv4> <port> : established sockets of <pid> towards ip:port
count_links() {
    local re="${2//./\\.}"
    ss -tnp state established 2>/dev/null \
        | grep -E "[[:space:]](\[::ffff:)?${re}\]?:${3}[[:space:]]" \
        | grep -c "pid=${1},"
}

# ---------------------------------------------------------------- validators
v_ipv4() {
    local ip="$1" o
    local IFS=.
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for o in $ip; do
        [ "$o" -le 255 ] || return 1
    done
    return 0
}
v_host() { v_ipv4 "$1" || [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
v_sni()  { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; }
v_pass() {
    [ -n "$1" ] || return 1
    [[ "$1" =~ [[:space:]] ]] && return 1
    case "$1" in
        *'$'*|*'%'*|*'\'*|*'"'*|*"'"*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'*'*|*'?'*) return 1 ;;
    esac
    return 0
}
v_posint() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; }
v_age()    { [[ "$1" =~ ^[0-9]+$ ]] && { [ "$1" -eq 0 ] || [ "$1" -ge 60 ]; }; }
v_range() {
    local a b
    [[ "$1" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
    a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
    [ "$a" -ge 23 ] && [ "$b" -le 65535 ] && [ "$a" -le "$b" ]
}
# range_has <a-b> <port>...  : true if ANY of the ports is inside the range
range_has() {
    local a=${1%-*} b=${1#*-} p
    shift
    for p in "$@"; do
        [ "$p" -ge "$a" ] && [ "$p" -le "$b" ] && return 0
    done
    return 1
}

# prompt_valid "<prompt>" <validator> "<error text>" [default]  -> $REPLY_VALUE
prompt_valid() {
    local v
    while true; do
        if ! read -r -p "$1" v; then
            echo
            echo "No input - aborting."
            exit 1
        fi
        v="${v:-$4}"
        if "$2" "$v"; then
            REPLY_VALUE="$v"
            return 0
        fi
        echo -e "${red}$3${rest}"
    done
}

confirm() {   # default answer is NO
    local a
    read -r -p "$1 [y/N]: " a || return 1
    [[ "$a" =~ ^[Yy] ]]
}

# -------------------------------------------------------------- system prep
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

# Only what RTT really needs (gcc / git / mtr / epel are no longer installed:
# they only slowed the install down and can fail on Iranian mirrors).
check_dependencies() {
    detect_distribution

    local missing=() dep
    for dep in wget curl unzip iptables lsof; do
        command -v "$dep" > /dev/null 2>&1 || missing+=("$dep")
    done
    if ! command -v ss > /dev/null 2>&1; then
        if [ "$package_manager" == "apt-get" ]; then missing+=("iproute2"); else missing+=("iproute"); fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${yellow}Installing missing packages: ${missing[*]}${rest}"
        if [ "$package_manager" == "apt-get" ]; then
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null 2>&1
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
        else
            $SUDO "${package_manager}" install -y "${missing[@]}"
        fi
    fi

    for dep in wget unzip iptables ss; do
        if ! command -v "$dep" > /dev/null 2>&1; then
            echo -e "${red}Required command '$dep' is still missing. Install it manually and run the script again.${rest}"
            exit 1
        fi
    done
}

# firewalld: only the Iran side needs the forwarded range open.
open_firewalld_range() {   # <a-b>
    if command -v firewall-cmd &> /dev/null && $SUDO systemctl is-active --quiet firewalld; then
        echo -e "${yellow}firewalld detected and active. Opening ${1}/tcp...${rest}"
        $SUDO firewall-cmd --permanent --add-port="${1}/tcp" > /dev/null 2>&1
        $SUDO firewall-cmd --reload > /dev/null 2>&1
    fi
}

prompt_keep_ufw() {
    KEEP_UFW_FLAG=""
    if command -v ufw &> /dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "${yellow}UFW is active on this server. By default RTT disables UFW when it starts.${rest}"
        read -r -p "Keep UFW active instead (adds --keep-ufw)? [yes/no] (default: no): " keep_ufw_choice
        if [ "$keep_ufw_choice" == "yes" ]; then
            KEEP_UFW_FLAG=" --keep-ufw"
        fi
    fi
}

open_ufw_range() {   # <a:b>
    if [ -n "$KEEP_UFW_FLAG" ]; then
        $SUDO ufw allow "${1}/tcp" > /dev/null 2>&1
    fi
}

# ---------------------------------------------------------------- pre-checks
ssh_ports() {
    {
        ss -tlnp 2>/dev/null | grep '"sshd"' | awk '{print $4}' | sed 's/.*://'
        [ -n "$SSH_CONNECTION" ] && echo "$SSH_CONNECTION" | awk '{print $4}'
    } | grep -E '^[0-9]+$' | sort -un
}

# RTT multiport redirects EVERY port of the range into the tunnel. If sshd is
# inside the range you lose SSH access (RTT docs warn about it).
choose_lport_range() {
    LPORT_RANGE="23-65535"
    local p conflict=() in first sug
    for p in $(ssh_ports); do
        [ "$p" -ge 23 ] && conflict+=("$p")
    done
    [ ${#conflict[@]} -eq 0 ] && return 0

    first=${conflict[0]}
    if [ "$first" -gt 443 ]; then sug="23-$((first - 1))"; else sug="$((first + 1))-65535"; fi
    echo -e "${red}WARNING: sshd listens on port(s): ${conflict[*]} - inside the forwarded range 23-65535.${rest}"
    echo -e "${yellow}RTT would redirect SSH into the tunnel and you would lose access to this server.${rest}"
    echo "Enter a range that includes 443 but excludes your SSH port(s), e.g. ${sug}, or type 'force' to keep 23-65535."
    while true; do
        read -r -p "Forward port range: " in || exit 1
        [ "$in" == "force" ] && return 0
        if v_range "$in" && range_has "$in" 443 && ! range_has "$in" "${conflict[@]}"; then
            LPORT_RANGE="$in"
            return 0
        fi
        echo -e "${red}Invalid. Use a range such as ${sug} that includes 443 and excludes: ${conflict[*]}${rest}"
    done
}

check_port_443_free() {
    local who
    who=$(ss -tlnp 2>/dev/null | awk '$4 ~ /[:.]443$/' | grep -oE '"[^"]+"' | head -n1)
    [ -n "$who" ] || return 0
    echo -e "${yellow}Port 443 is already in use by ${who}.${rest}"
    echo "The Kharej connects to port 443 of this Iran server, so nothing else may use it."
    confirm "Continue anyway?" || { echo "Aborted."; exit 1; }
}

# RTT fails with "Resource temporarily unavailable" when the SNI has no IP.
check_sni_dns() {
    if ! timeout 6 getent hosts "$1" > /dev/null 2>&1; then
        echo -e "${yellow}Warning: this server cannot resolve '$1'.${rest}"
        echo -e "${yellow}RTT fails with 'Resource temporarily unavailable' when the SNI domain has no IP. Pick another SNI or fix the DNS resolvers (e.g. 1.1.1.1 / 8.8.8.8).${rest}"
    fi
}

check_iran_reachable() {   # <ip> <port>
    if timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then
        echo -e "${green}Iran server $1:$2 is reachable.${rest}"
    else
        echo -e "${yellow}Cannot reach $1:$2 right now. Expected if the Iran side is not installed/started yet; otherwise check the IP and the Iran firewall (port $2).${rest}"
    fi
}

# Flags shared by every new install (both roles).
compute_common_flags() {
    KEEP_OS_LIMIT_FLAG=""
    CONN_AGE_FLAG=""
    local v
    if [ ! -w /proc/sys/fs/file-max ]; then
        KEEP_OS_LIMIT_FLAG=" --keep-os-limit"
        echo -e "${yellow}Cannot raise fs.file-max here (container?) - adding --keep-os-limit.${rest}"
    fi
    v=$(rtt_version)
    if [ -z "$v" ] || version_gt "$v" "5.4"; then
        CONN_AGE_FLAG=" --connection-age:$CONN_AGE"
    else
        echo -e "${yellow}RTT $v is older than 5.5 - skipping --connection-age.${rest}"
    fi
}

# ------------------------------------------------- kernel / MSS / hardening
is_iran_role() {
    local svc
    while read -r svc; do
        [ -n "$svc" ] || continue
        [ "$(service_role "$svc")" == "iran" ] && return 0
    done < <(list_rtt_services)
    return 1
}

write_mss_clamp() {
    {
        echo '#!/bin/bash'
        echo "MSS=$TUNNEL_MSS"
        cat <<'EOF'
# Clamp the MSS of TCP SYN packets so tunnel traffic never needs fragmentation
# (PMTU black holes are a classic cause of "connected but stalled" tunnels).
# Loopback is skipped: Kharej -> 127.0.0.1 traffic keeps its large MSS.
ipt() { timeout 15 iptables -w "$@"; }
# remove rules written by older versions (they had no interface match)
for ch in INPUT OUTPUT; do
    while ipt -t mangle -D "$ch" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null; do :; done
done
ensure() {
    local chain="$1"
    shift
    ipt -t mangle -C "$chain" "$@" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS" 2>/dev/null \
        || ipt -t mangle -A "$chain" "$@" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS"
}
ensure INPUT  ! -i lo
ensure OUTPUT ! -o lo
ensure FORWARD
exit 0
EOF
    } > "$MSS_CLAMP_SCRIPT"
    chmod +x "$MSS_CLAMP_SCRIPT"

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
}

# One drop-in per RTT unit (survives re-installs, works for every unit type):
# fast restart, big fd limit, and the OOM killer must not pick the tunnel first.
harden_services() {
    local svc d pid
    while read -r svc; do
        [ -n "$svc" ] || continue
        d="$UNIT_DIR/${svc}.d"
        mkdir -p "$d"
        cat > "$d/10-rtt-stability.conf" <<'EOF'
[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-500
EOF
        pid=$(service_pid "$svc")
        if [ "$pid" -gt 0 ]; then
            { echo -500 > "/proc/$pid/oom_score_adj"; } 2>/dev/null
        fi
    done < <(list_rtt_services)
    $SUDO systemctl daemon-reload
}

apply_kernel_tuning() {
    echo -e "${cyan}===> Applying kernel/network stability profile...${rest}"

    local cc="bbr" qdisc="fq" mem_mb ct_max ct_block=""
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
        && ! modprobe tcp_bbr 2>/dev/null; then
        echo -e "${yellow}BBR module not available, falling back to cubic + fq_codel.${rest}"
        cc="cubic"
        qdisc="fq_codel"
    fi

    mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    if   [ "${mem_mb:-0}" -ge 3500 ]; then ct_max=524288
    elif [ "${mem_mb:-0}" -ge 1500 ]; then ct_max=262144
    else ct_max=131072
    fi

    # Iran side: multiport mode uses iptables NAT, i.e. connection tracking.
    if is_iran_role; then
        modprobe nf_conntrack 2>/dev/null
        mkdir -p "$(dirname "$MODULES_FILE")"
        printf 'nf_conntrack\n' > "$MODULES_FILE"
        [ "$cc" == "bbr" ] && printf 'tcp_bbr\n' >> "$MODULES_FILE"
    fi
    if [ -e "$CT_MAX_PATH" ]; then
        ct_block="# Conntrack: bigger table; silently dead entries expire after 1 day instead of 5
net.netfilter.nf_conntrack_max = $ct_max
net.netfilter.nf_conntrack_tcp_timeout_established = 86400"
    fi

    cat <<EOF > "$SYSCTL_FILE"
# RTT tunnel stability profile (v5.0) - generated by the RTT installer

# Congestion control
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc

# Buffers: enough for a 100+ Mbit/s long-RTT path, small enough for tiny VPSes
net.core.netdev_max_backlog = 10000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 212992
net.core.wmem_default = 212992
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_moderate_rcvbuf = 1

# Tunnel responsiveness
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

# Disable TCP FastOpen (prevents DPI drops in Iran)
net.ipv4.tcp_fastopen = 0

# Probe the path MTU when ICMP is filtered (PMTU black hole => stalled tunnel)
net.ipv4.tcp_mtu_probing = 1

# Dead-connection detection: a silently dropped tunnel connection is declared
# dead after ~2-6 minutes instead of ~15, so RTT re-creates it quickly.
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1

# Listen / SYN backlog
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535

# Standard reordering handling
net.ipv4.tcp_reordering = 3
net.ipv4.tcp_max_reordering = 300
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

fs.file-max = 2097152
$ct_block
EOF

    if ! $SUDO sysctl -e -q -p "$SYSCTL_FILE" > /dev/null 2>&1; then
        echo -e "${yellow}Some kernel parameters could not be applied (normal on containers / OpenVZ).${rest}"
    fi

    write_mss_clamp
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable rtt-mss-clamp.service > /dev/null 2>&1
    $SUDO systemctl restart rtt-mss-clamp.service > /dev/null 2>&1

    harden_services

    echo -e "${green}===> Tuning applied. Congestion control=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null), tcp_retries2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null)${rest}"
}

# ------------------------------------------------------ RTT binary handling
stop_all_rtt_services() {
    local svc
    while read -r svc; do
        [ -n "$svc" ] && $SUDO systemctl stop "$svc" 2>/dev/null
    done < <(list_rtt_services)
    pkill -x RTT 2>/dev/null
    sleep 1
}

# services stopped on purpose from the menu stay stopped
restart_all_rtt_services() {
    local svc
    while read -r svc; do
        [ -n "$svc" ] || continue
        [ -f "$MANUAL_DIR/$svc.manual_stop" ] && continue
        $SUDO systemctl restart "$svc" 2>/dev/null
    done < <(list_rtt_services)
}

# Latest version through the upstream installer. Services are stopped while the
# binary is replaced and ALWAYS started again, even when the download failed.
install_rtt() {
    local rc=0
    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; return 1; }
    stop_all_rtt_services

    if ! wget --timeout=20 --tries=3 "$RTT_INSTALLER_URL" -O install.sh; then
        echo -e "${red}Failed to download install.sh (is GitHub reachable from this server?).${rest}"
        rc=1
    else
        chmod +x install.sh
        if ! bash install.sh; then
            echo -e "${red}install.sh failed to run correctly.${rest}"
            rc=1
        fi
    fi

    if [ -f "$INSTALL_DIR/RTT" ]; then
        chmod +x "$INSTALL_DIR/RTT"
    else
        echo -e "${red}RTT binary not found after install.${rest}"
        rc=1
    fi

    restart_all_rtt_services
    return $rc
}

install_rtt_custom() {
    local version arch URL OUT_FILE rc=0
    read -r -p "Please enter your custom version (e.g. 7.1): " version
    if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo -e "${red}Invalid version.${rest}"
        return 1
    fi
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) echo "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
    URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V${version}/v${version}_linux_${arch}.zip"
    OUT_FILE="v${version}_linux_${arch}.zip"

    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; return 1; }
    stop_all_rtt_services

    if ! wget --timeout=20 --tries=3 "$URL" -O "$OUT_FILE"; then
        echo -e "${red}Failed to download RTT version $version.${rest}"
        rc=1
    elif ! unzip -o "$OUT_FILE"; then
        echo -e "${red}Failed to unzip $OUT_FILE.${rest}"
        rc=1
    fi
    rm -f "$OUT_FILE"
    [ -f "$INSTALL_DIR/RTT" ] && chmod +x "$INSTALL_DIR/RTT"

    restart_all_rtt_services
    return $rc
}

install_selected_version() {
    local choice rc
    read -r -p "Do you want to install the Latest version? [yes/no] (default: yes): " choice
    if [[ "$choice" == "no" ]]; then
        install_rtt_custom
    else
        install_rtt
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ -x "$INSTALL_DIR/RTT" ]; then
            echo -e "${yellow}Download/update failed - continuing with the RTT binary already in $INSTALL_DIR.${rest}"
        else
            echo -e "${red}No RTT binary available. If GitHub is blocked on this server, copy the RTT binary to $INSTALL_DIR/RTT (scp), run: chmod +x $INSTALL_DIR/RTT and start this script again.${rest}"
            exit 1
        fi
    fi
}

check_installed() {
    if [ -f "$UNIT_DIR/tunnel.service" ]; then
        echo "The service is already installed."
        exit 1
    fi
}

check_lbinstalled() {
    if [ -f "$UNIT_DIR/lbtunnel.service" ]; then
        echo "The Load-balancer is already installed."
        exit 1
    fi
}

# ------------------------------------------------------------ configuration
# Sets $server_choice (1=Iran, 2=Kharej) and $arguments.
configure_arguments() {
    local server_ip password sni use_fake ratio noise_flag=""
    read -r -p "Which server do you want to use? (1 for Iran, 2 for Kharej): " server_choice
    case "$server_choice" in
        1|2) ;;
        *) echo "Invalid choice. Please enter '1' or '2'."; exit 1 ;;
    esac

    prompt_valid "Please enter SNI (default: sheypoor.com): " v_sni \
        "Invalid SNI - use a plain domain such as sheypoor.com" "sheypoor.com"
    sni="$REPLY_VALUE"
    check_sni_dns "$sni"

    prompt_keep_ufw
    compute_common_flags

    if [ "$server_choice" == "2" ]; then
        prompt_valid "Please enter IRAN IP (internal-server): " v_host "Invalid IP / hostname."
        server_ip="$REPLY_VALUE"
        prompt_valid "Please enter password: " v_pass "$PASS_HINT"
        password="$REPLY_VALUE"
        check_iran_reachable "$server_ip" 443
        arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni$KEEP_UFW_FLAG$KEEP_OS_LIMIT_FLAG$CONN_AGE_FLAG"
    else
        prompt_valid "Please enter password: " v_pass "$PASS_HINT"
        password="$REPLY_VALUE"
        choose_lport_range
        check_port_443_free
        read -r -p "Do you want to use fake upload? (yes/no): " use_fake
        if [ "$use_fake" == "yes" ]; then
            prompt_valid "Enter upload-to-download ratio (e.g. 5 for 5:1): " v_posint "Enter a whole number >= 1."
            ratio="$REPLY_VALUE"
            [ "$ratio" -gt 1 ] && noise_flag=" --noise:$((ratio - 1))"
        fi
        arguments="--iran --lport:$LPORT_RANGE --sni:$sni --password:$password$noise_flag$KEEP_UFW_FLAG$KEEP_OS_LIMIT_FLAG$CONN_AGE_FLAG"
        open_ufw_range "${LPORT_RANGE/-/:}"
        open_firewalld_range "$LPORT_RANGE"
    fi
}

configure_arguments2() {
    local server_ip password sni is_main_server main_ip ip num_ips use_fake ratio noise_flag=""
    read -r -p "Which server do you want to use? (1 for Iran, 2 for Kharej): " server_choice
    case "$server_choice" in
        1|2) ;;
        *) echo "Invalid choice. Please enter '1' or '2'."; exit 1 ;;
    esac

    prompt_valid "Please enter SNI (default: sheypoor.com): " v_sni \
        "Invalid SNI - use a plain domain such as sheypoor.com" "sheypoor.com"
    sni="$REPLY_VALUE"
    check_sni_dns "$sni"

    prompt_keep_ufw
    compute_common_flags

    if [ "$server_choice" == "2" ]; then
        read -r -p "Is this your main server (VPN server)? (yes/no): " is_main_server
        prompt_valid "Please enter IRAN IP: " v_host "Invalid IP / hostname."
        server_ip="$REPLY_VALUE"
        prompt_valid "Please enter password: " v_pass "$PASS_HINT"
        password="$REPLY_VALUE"
        check_iran_reachable "$server_ip" 443

        if [ "$is_main_server" == "yes" ]; then
            main_ip="127.0.0.1"
        else
            prompt_valid "Enter your main IP (VPN server): " v_host "Invalid IP / hostname."
            main_ip="$REPLY_VALUE"
        fi
        arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:$main_ip --toport:multiport --password:$password --sni:$sni$KEEP_UFW_FLAG$KEEP_OS_LIMIT_FLAG$CONN_AGE_FLAG"
    else
        prompt_valid "Please enter password: " v_pass "$PASS_HINT"
        password="$REPLY_VALUE"
        choose_lport_range
        check_port_443_free
        read -r -p "Do you want to use fake upload? (yes/no): " use_fake
        if [ "$use_fake" == "yes" ]; then
            prompt_valid "Enter upload-to-download ratio (e.g. 5 for 5:1): " v_posint "Enter a whole number >= 1."
            ratio="$REPLY_VALUE"
            [ "$ratio" -gt 1 ] && noise_flag=" --noise:$((ratio - 1))"
        fi
        arguments="--iran --lport:$LPORT_RANGE --password:$password --sni:$sni$noise_flag$KEEP_UFW_FLAG$KEEP_OS_LIMIT_FLAG$CONN_AGE_FLAG"
        open_ufw_range "${LPORT_RANGE/-/:}"
        open_firewalld_range "$LPORT_RANGE"

        num_ips=0
        while true; do
            num_ips=$((num_ips + 1))
            read -r -p "Please enter IP of peer server $num_ips (or type 'done' to finish): " ip || break
            if [ "$ip" == "done" ]; then
                break
            elif v_host "$ip"; then
                arguments="$arguments --peer:$ip"
            else
                echo -e "${red}Invalid IP / hostname.${rest}"
                num_ips=$((num_ips - 1))
            fi
        done
    fi
}

# write_unit <unit file> <description> <full command line>
write_unit() {
    cat <<EOL > "$UNIT_DIR/$1"
[Unit]
Description=$2
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$3
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOL
}

# verify_after_install <unit> <1=Iran|2=Kharej>
verify_after_install() {
    local svc="$1" role="$2" pid i ip port
    echo -e "${cyan}===> Checking that the tunnel stays up...${rest}"

    if ! service_stable "$svc"; then
        echo -e "${red}$svc is not staying up.${rest}"
        if grep -q -- '--connection-age' "$UNIT_DIR/$svc"; then
            echo -e "${yellow}Retrying without --connection-age (this RTT build may not support it)...${rest}"
            set_exec_option "$svc" --connection-age "" remove
            $SUDO systemctl daemon-reload
            $SUDO systemctl restart "$svc"
            if service_stable "$svc"; then
                echo -e "${yellow}Running without --connection-age.${rest}"
            else
                echo -e "${red}Still failing. Check: journalctl -u $svc -n 50${rest}"
                return 1
            fi
        else
            echo -e "${red}Check: journalctl -u $svc -n 50${rest}"
            return 1
        fi
    fi

    pid=$(service_pid "$svc")
    if [ "$role" == "1" ]; then
        # Iran role: RTT must actually bind a listening socket. is-active alone
        # does not prove that - it only proves the process launched.
        for i in 1 2 3 4 5; do
            listening_ok "$pid" && break
            sleep 2
        done
        if listening_ok "$pid"; then
            echo -e "${green}Tunnel service started successfully and is listening.${rest}"
        else
            echo -e "${yellow}Tunnel service is running but is NOT listening yet.${rest}"
            echo -e "${yellow}Give it a few more seconds, then check: journalctl -u $svc -n 50${rest}"
        fi
    else
        ip=$(exec_arg "$svc" --iran-ip)
        port=$(exec_arg "$svc" --iran-port)
        port=${port:-443}
        if v_ipv4 "$ip"; then
            for i in $(seq 1 15); do
                [ "$(count_links "$pid" "$ip" "$port")" -gt 0 ] && break
                sleep 2
            done
            if [ "$(count_links "$pid" "$ip" "$port")" -gt 0 ]; then
                echo -e "${green}Tunnel is UP: live connection to $ip:$port.${rest}"
            else
                echo -e "${yellow}No live connection to $ip:$port yet. Most common causes:${rest}"
                echo -e "${yellow}  1) the Iran side is not installed/started yet, or its firewall blocks port $port${rest}"
                echo -e "${yellow}  2) password or SNI differ between the two servers${rest}"
                echo -e "${yellow}  3) the SNI domain cannot be resolved (menu 9 shows it)${rest}"
                echo -e "${yellow}Logs: journalctl -u $svc -n 50${rest}"
            fi
        else
            echo -e "${green}Tunnel service started successfully.${rest}"
            echo -e "${yellow}Note: this is a Kharej client - it makes an outbound connection, it won't show as 'listening'. Confirm the Iran side sees an active peer too.${rest}"
        fi
    fi
}

show_peer_reminder() {
    echo -e "${yellow}Reminder: the OTHER server must use the SAME password and SNI, and --connection-age must be on BOTH sides (menu 8 on an older install).${rest}"
}

# ------------------------------------------------------------- install flows
install() {
    root_access
    check_dependencies
    check_installed
    install_selected_version

    configure_arguments

    write_unit tunnel.service "RTT Tunnel Service" "$INSTALL_DIR/RTT $arguments"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable tunnel.service > /dev/null 2>&1
    rm -f "$MANUAL_DIR/tunnel.service.manual_stop"

    apply_kernel_tuning
    install_watchdog

    $SUDO systemctl restart tunnel.service
    verify_after_install tunnel.service "$server_choice"
    show_peer_reminder
}

load-balancer() {
    root_access
    check_dependencies
    check_lbinstalled
    install_selected_version

    configure_arguments2

    write_unit lbtunnel.service "RTT Load-balancer Service" "$INSTALL_DIR/RTT $arguments"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable lbtunnel.service > /dev/null 2>&1
    rm -f "$MANUAL_DIR/lbtunnel.service.manual_stop"

    apply_kernel_tuning
    install_watchdog

    $SUDO systemctl restart lbtunnel.service
    verify_after_install lbtunnel.service "$server_choice"
    show_peer_reminder
}

# Custom command (not in the menu, kept for compatibility): the text you enter
# must start with RTT, e.g.  RTT --iran --lport:443 --sni:x.ir --password:123
install_custom() {
    root_access
    check_dependencies
    install_selected_version
    read -r -p "Enter RTT arguments: " arguments

    write_unit custom_tunnel.service "RTT Custom Tunnel Service" "$INSTALL_DIR/$arguments"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable custom_tunnel.service > /dev/null 2>&1
    apply_kernel_tuning
    install_watchdog
    $SUDO systemctl restart custom_tunnel.service
}

# ------------------------------------------------- editing existing services
# set_exec_option <unit> <--option> <value|""> <set|remove>
# Adds / replaces / removes "--option:value" (or a bare "--option") in ExecStart.
set_exec_option() {
    local path="$UNIT_DIR/$1" opt="$2" val="$3" mode="${4:-set}"
    local line tok new tmp
    local -a toks out=()
    line=$(grep -m1 '^ExecStart=' "$path") || return 1
    IFS=' ' read -r -a toks <<< "${line#ExecStart=}"
    for tok in "${toks[@]}"; do
        case "$tok" in
            "$opt"|"$opt":*) ;;                 # drop the old occurrence
            *) out+=("$tok") ;;
        esac
    done
    if [ "$mode" == "set" ]; then
        if [ -n "$val" ]; then out+=("$opt:$val"); else out+=("$opt"); fi
    fi
    new="ExecStart=${out[*]}"
    tmp=$(mktemp) || return 1
    NEWLINE="$new" awk 'BEGIN{d=0} /^ExecStart=/ && !d {print ENVIRON["NEWLINE"]; d=1; next} {print}' "$path" > "$tmp" \
        && cat "$tmp" > "$path"
    rm -f "$tmp"
}

# Edit + restart + prove the service stays up; otherwise restore the old unit.
apply_exec_change() {   # <unit> <--option> <value|""> <set|remove>
    local svc="$1" path="$UNIT_DIR/$1" bak
    mkdir -p "$BACKUP_DIR"
    bak="$BACKUP_DIR/$svc.prev"
    cp -p "$path" "$bak" || return 1
    set_exec_option "$svc" "$2" "$3" "${4:-set}" || return 1
    $SUDO systemctl daemon-reload
    if [ -f "$MANUAL_DIR/$svc.manual_stop" ]; then
        echo -e "${yellow}$svc is stopped on purpose - change saved, not starting it.${rest}"
        return 0
    fi
    $SUDO systemctl restart "$svc"
    if service_stable "$svc"; then
        return 0
    fi
    echo -e "${red}$svc did not stay up with the new setting - rolling back.${rest}"
    cp -p "$bak" "$path"
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart "$svc"
    return 1
}

sync_prompt() {
    echo -e "${yellow}--connection-age must be set on BOTH servers and the tunnels restarted at about the same time.${rest}"
    echo "Run this same menu option on the other server now, then press Enter on both."
    read -r -t 300 -p "Press Enter to apply and restart the tunnel here (Ctrl+C to cancel)... " _ || true
    echo
}

# apply_connection_age <seconds | 0 = remove the switch>
apply_connection_age() {
    local val="$1" svc mode ok=0 bad=0 v
    v=$(rtt_version)
    if [ "$val" != "0" ] && [ -n "$v" ] && ! version_gt "$v" "5.4"; then
        echo -e "${yellow}RTT $v is older than 5.5 - --connection-age is not supported. Skipping.${rest}"
        return 0
    fi
    while read -r svc; do
        [ -n "$svc" ] || continue
        [ "$(service_role "$svc")" == "other" ] && continue
        if [ "$val" == "0" ]; then mode=remove; else mode=set; fi
        if apply_exec_change "$svc" --connection-age "$([ "$val" == "0" ] || echo "$val")" "$mode"; then
            ok=$((ok + 1))
        else
            bad=$((bad + 1))
        fi
    done < <(list_rtt_services)

    if [ "$ok" -gt 0 ] && [ "$bad" -eq 0 ]; then
        if [ "$val" == "0" ]; then
            echo -e "${green}--connection-age removed from $ok service(s).${rest}"
        else
            echo -e "${green}--connection-age:$val is active on $ok service(s).${rest}"
        fi
    fi
    if [ "$bad" -gt 0 ]; then
        echo -e "${red}$bad service(s) rejected the change and were rolled back (this RTT build may not support --connection-age).${rest}"
    fi
}

# Menu 22
set_connection_age() {
    root_access
    local val
    if [ -z "$(list_rtt_services)" ]; then
        echo -e "${red}No RTT service installed.${rest}"
        return
    fi
    prompt_valid "connection-age in seconds (default $CONN_AGE, 0 = remove the switch): " v_age \
        "Enter 0 or a number >= 60." "$CONN_AGE"
    val="$REPLY_VALUE"
    sync_prompt
    apply_connection_age "$val"
    echo -e "${yellow}Now do the same on the other server.${rest}"
}

# Menu 8: everything for an install that already exists (no reinstall needed)
apply_all_fixes() {
    root_access
    if [ -z "$(list_rtt_services)" ]; then
        echo -e "${red}No RTT service installed - use option 1 (or 6) first.${rest}"
        return
    fi
    echo -e "${cyan}===> 1/3 Kernel profile, MSS clamp, service hardening${rest}"
    apply_kernel_tuning
    echo -e "${cyan}===> 2/3 Watchdog${rest}"
    install_watchdog
    echo -e "${cyan}===> 3/3 --connection-age:$CONN_AGE (RTT author's fix for random drops)${rest}"
    sync_prompt
    apply_connection_age "$CONN_AGE"
    echo -e "${green}Done. Run the same option on the OTHER server (at the same time), then use option 9 to verify the link.${rest}"
}

# change_service_option <--option> <label> <validator> <error hint> [dns]
change_service_option() {
    root_access
    local opt="$1" label="$2" validator="$3" hint="$4" check_dns="$5"
    local svc cur="" n=0 val
    if [ -z "$(list_rtt_services)" ]; then
        echo -e "${red}No RTT service installed.${rest}"
        return
    fi
    while read -r svc; do
        [ -n "$svc" ] || continue
        cur=$(exec_arg "$svc" "$opt")
        [ -n "$cur" ] && break
    done < <(list_rtt_services)
    if [ -z "$cur" ]; then
        echo -e "${red}$label is not used by the installed RTT service(s) on this server.${rest}"
        return
    fi
    if [ "$opt" == "--password" ]; then
        echo "Current $label: (hidden)"
    else
        echo -e "Current $label: ${cyan}$cur${rest}"
    fi
    prompt_valid "Enter new $label: " "$validator" "$hint"
    val="$REPLY_VALUE"
    [ -n "$check_dns" ] && check_sni_dns "$val"

    while read -r svc; do
        [ -n "$svc" ] || continue
        [ -n "$(exec_arg "$svc" "$opt")" ] || continue
        if apply_exec_change "$svc" "$opt" "$val" set; then
            n=$((n + 1))
        fi
    done < <(list_rtt_services)

    if [ "$n" -gt 0 ]; then
        echo -e "${green}$label updated on $n service(s) and restarted.${rest}"
        if [ "$opt" != "--iran-ip" ]; then
            echo -e "${yellow}The $label must be IDENTICAL on the other server - change it there too.${rest}"
        fi
    fi
}

change_sni()      { change_service_option --sni "SNI" v_sni "Invalid SNI - use a plain domain such as sheypoor.com" dns; }
change_password() { change_service_option --password "password" v_pass "$PASS_HINT"; }
change_iran_ip()  { change_service_option --iran-ip "IRAN IP" v_host "Invalid IP / hostname."; }

# ----------------------------------------------------- diagnostics and logs
diagnose() {
    root_access
    local svc role pid ip port sni links est v
    local -a svcs=()
    mapfile -t svcs < <(list_rtt_services)

    echo -e "${cyan}=============== RTT diagnostics ($(date '+%F %T')) ===============${rest}"
    if [ ${#svcs[@]} -eq 0 ]; then
        echo -e "${red}No RTT service is installed on this server.${rest}"
        return
    fi
    v=$(rtt_version)
    echo "RTT binary  : ${v:-unknown}    watchdog timer: $(systemctl is-active rtt-watchdog.timer 2>/dev/null)"

    for svc in "${svcs[@]}"; do
        role=$(service_role "$svc")
        pid=$(service_pid "$svc")
        echo -e "\n${yellow}--- $svc (role: $role) ---${rest}"
        echo "State       : $(systemctl is-active "$svc" 2>/dev/null) / enabled: $(systemctl is-enabled "$svc" 2>/dev/null)"
        if [ "$pid" -gt 0 ]; then
            echo "Process     : pid $pid, running $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
        fi
        echo "Restarts    : $(systemctl show -p NRestarts "$svc" 2>/dev/null | cut -d= -f2)"
        echo "Command     : $(exec_line_of "$svc" | sed 's/^ExecStart=//' | mask_args)"
        if grep -q -- '--connection-age' "$UNIT_DIR/$svc"; then
            echo -e "connection-age: ${green}ON${rest}"
        else
            echo -e "connection-age: ${red}OFF${rest}  <-- run menu 8 (on both servers)"
        fi

        sni=$(exec_arg "$svc" --sni)
        if [ -n "$sni" ]; then
            if timeout 6 getent hosts "$sni" > /dev/null 2>&1; then
                echo -e "SNI DNS     : $sni ${green}resolves${rest}"
            else
                echo -e "SNI DNS     : $sni ${red}does NOT resolve${rest}  <-- fix DNS or change the SNI (menu 19)"
            fi
        fi

        case "$role" in
            kharej)
                ip=$(exec_arg "$svc" --iran-ip)
                port=$(exec_arg "$svc" --iran-port)
                port=${port:-443}
                if timeout 5 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
                    echo -e "Iran $ip:$port : ${green}reachable${rest}"
                else
                    echo -e "Iran $ip:$port : ${red}NOT reachable${rest}  (Iran down? firewall? wrong IP?)"
                fi
                if v_ipv4 "$ip" && [ "$pid" -gt 0 ]; then
                    links=$(count_links "$pid" "$ip" "$port")
                    if [ "${links:-0}" -gt 0 ]; then
                        echo -e "Tunnel links: ${green}$links live connection(s)${rest}"
                    else
                        echo -e "Tunnel links: ${red}0 - the tunnel is DOWN${rest}"
                    fi
                fi
                ;;
            iran)
                if [ "$pid" -gt 0 ] && listening_ok "$pid"; then
                    echo -e "Listening   : ${green}yes${rest}"
                else
                    echo -e "Listening   : ${red}NO${rest}"
                fi
                est=$(ss -tn state established '( sport = :443 )' 2>/dev/null | tail -n +2 | wc -l)
                echo "Established : $est connection(s) on :443 (the Kharej side shows up here)"
                ;;
        esac

        echo "Last log lines:"
        journalctl -u "$svc" -n 8 --no-pager 2>/dev/null | cut -c1-180 | sed 's/^/    /'
    done

    echo -e "\n${yellow}--- kernel / network ---${rest}"
    echo "Congestion control : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)   qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "tcp_retries2       : $(sysctl -n net.ipv4.tcp_retries2 2>/dev/null)   (profile: 8)"
    echo "tcp_mtu_probing    : $(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)   (profile: 1)"
    if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
        echo "Conntrack          : $(cat /proc/sys/net/netfilter/nf_conntrack_count) / $(cat "$CT_MAX_PATH" 2>/dev/null)"
    fi
    echo "MSS clamp rules    : $(iptables -t mangle -S 2>/dev/null | grep -c -- "--set-mss $TUNNEL_MSS")   (expected 3)"
    echo -e "\n${cyan}If the tunnel is DOWN: compare password + SNI on both servers (menus 19/20), make sure Iran port 443 is open, then run menu 8 on BOTH servers at the same time.${rest}"
}

show_logs() {
    local svc
    while read -r svc; do
        [ -n "$svc" ] || continue
        echo -e "${yellow}--- $svc ---${rest}"
        journalctl -u "$svc" -n 60 --no-pager 2>/dev/null
    done < <(list_rtt_services)
}

# ------------------------------------------------------------------ watchdog
install_watchdog() {
    root_access
    echo -e "${cyan}===> Installing the connection watchdog (v5)...${rest}"
    mkdir -p "$STATE_DIR" "$MANUAL_DIR"

    cat <<'WDEOF' > "$WATCHDOG_SCRIPT"
#!/bin/bash
# RTT watchdog v5 - conservative self-healing for the RTT services.
# It only acts on CLEAR failures. It never touches a tunnel that was stopped
# on purpose (menu option 4) and never fights systemd while it is restarting.

UNIT_DIR="/etc/systemd/system"
STATE_DIR="/var/lib/rtt-watchdog"
MANUAL_DIR="/run/rtt-watchdog"
MSS_CLAMP_SCRIPT="/usr/local/sbin/rtt-mss-clamp.sh"
MIN_RESTART_GAP=120     # seconds between two watchdog restarts of one service
SETTLE_TIME=45          # seconds a (re)started process gets before it is judged
LINK_FAIL_LIMIT=5       # Kharej: consecutive minutes without ANY link to Iran
DSTATE_LIMIT=3          # consecutive minutes in uninterruptible sleep
NOLISTEN_LIMIT=2        # Iran: consecutive minutes without a listening socket

mkdir -p "$STATE_DIR"

log()  { logger -t rtt-watchdog -- "$1"; }
prop() { systemctl show -p "$2" "$1" 2>/dev/null | cut -d= -f2-; }   # portable, no --value

# bump <svc> <name> -> prints the new consecutive-failure count
bump() {
    local f="$STATE_DIR/$1.$2" n=0
    [ -f "$f" ] && n=$(cat "$f" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$((n + 1))
    echo "$n" > "$f"
    echo "$n"
}
clear_count() { rm -f "$STATE_DIR/$1.$2"; }

restart_service() {
    local svc="$1" reason="$2" last_file="$STATE_DIR/$1.last_restart" now last diff
    now=$(date +%s)
    if [ -f "$last_file" ]; then
        last=$(cat "$last_file" 2>/dev/null)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        diff=$((now - last))
        if [ "$diff" -lt "$MIN_RESTART_GAP" ]; then
            log "$svc: needs restart ($reason) but only ${diff}s since the last one - skipping."
            return
        fi
    fi
    log "$svc: restarting - $reason"
    systemctl reset-failed "$svc" 2>/dev/null
    systemctl restart "$svc" 2>/dev/null
    echo "$now" > "$last_file"
}

# established sockets of <pid> towards <ipv4>:<port>
count_links() {
    local re="${2//./\\.}"
    ss -tnp state established 2>/dev/null \
        | grep -E "[[:space:]](\[::ffff:)?${re}\]?:${3}[[:space:]]" \
        | grep -c "pid=${1},"
}

# Iran role: the process must own a listening socket.
check_iran() {
    local svc="$1" pid="$2"
    if ss -tlnp 2>/dev/null | grep -q "pid=${pid},"; then
        clear_count "$svc" nolisten
    elif [ "$(bump "$svc" nolisten)" -ge "$NOLISTEN_LIMIT" ]; then
        clear_count "$svc" nolisten
        restart_service "$svc" "Iran process is running but not listening ($NOLISTEN_LIMIT checks in a row)"
    fi
}

# Kharej role: it never listens (outbound client), but a healthy one always
# holds live connections to Iran. None for LINK_FAIL_LIMIT minutes = dead tunnel.
check_kharej() {
    local svc="$1" pid="$2" line="$3" ip port links n
    ip=$(printf '%s\n' "$line" | tr ' ' '\n' | sed -n 's/^--iran-ip://p' | head -n1)
    port=$(printf '%s\n' "$line" | tr ' ' '\n' | sed -n 's/^--iran-port://p' | head -n1)
    [[ "$port" =~ ^[0-9]+$ ]] || port=443
    # only IPv4 literals can be matched reliably in the ss output
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
    links=$(count_links "$pid" "$ip" "$port")
    if [ "${links:-0}" -gt 0 ]; then
        clear_count "$svc" nolink
    else
        n=$(bump "$svc" nolink)
        if [ "$n" -ge "$LINK_FAIL_LIMIT" ]; then
            clear_count "$svc" nolink
            restart_service "$svc" "no live tunnel connection to $ip:$port for $n checks in a row"
        fi
    fi
}

check_service() {
    local svc="$1" path="$UNIT_DIR/$1" state pid etime line
    [ -f "$path" ] || return
    systemctl is-enabled --quiet "$svc" 2>/dev/null || return
    [ -f "$MANUAL_DIR/$svc.manual_stop" ] && return      # stopped on purpose

    state=$(systemctl is-active "$svc" 2>/dev/null)
    case "$state" in
        active) ;;
        activating|reloading|deactivating) return ;;      # systemd is already on it
        *) restart_service "$svc" "service state is '$state'"; return ;;
    esac

    pid=$(prop "$svc" MainPID)
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 0 ] || ! kill -0 "$pid" 2>/dev/null; then
        restart_service "$svc" "main process (pid '$pid') is gone"
        return
    fi

    # give a freshly (re)started process time to settle before judging it
    etime=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ "$etime" =~ ^[0-9]+$ ]] || etime=999999
    [ "$etime" -lt "$SETTLE_TIME" ] && return

    if [ "$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')" == "D" ]; then
        if [ "$(bump "$svc" dstate)" -ge "$DSTATE_LIMIT" ]; then
            clear_count "$svc" dstate
            restart_service "$svc" "process stuck in D-state for $DSTATE_LIMIT checks in a row"
            return
        fi
    else
        clear_count "$svc" dstate
    fi

    line=$(grep -m1 '^ExecStart=' "$path")
    if   [[ "$line" == *" --kharej"* ]]; then check_kharej "$svc" "$pid" "$line"
    elif [[ "$line" == *" --iran"*   ]]; then check_iran "$svc" "$pid"
    fi
}

# Something (ufw reload, RTT start, another script) may flush the mangle table.
ensure_mss_clamp() {
    [ -x "$MSS_CLAMP_SCRIPT" ] || return
    command -v iptables > /dev/null 2>&1 || return
    local mss n n2 now last
    mss=$(sed -n 's/^MSS=//p' "$MSS_CLAMP_SCRIPT" | head -n1)
    [[ "$mss" =~ ^[0-9]+$ ]] || return
    n=$(timeout 10 iptables -w -t mangle -S 2>/dev/null | grep -c -- "--set-mss $mss")
    [ "${n:-0}" -ge 3 ] && { rm -f "$STATE_DIR/mss.fail"; return; }

    "$MSS_CLAMP_SCRIPT" > /dev/null 2>&1
    n2=$(timeout 10 iptables -w -t mangle -S 2>/dev/null | grep -c -- "--set-mss $mss")
    if [ "${n2:-0}" -ge 3 ]; then
        log "MSS clamp rules were missing - re-applied."
        rm -f "$STATE_DIR/mss.fail"
    else
        now=$(date +%s)
        last=$(cat "$STATE_DIR/mss.fail" 2>/dev/null)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if [ $((now - last)) -ge 3600 ]; then
            log "MSS clamp could not be applied (iptables / xt_TCPMSS problem?) - tunnel itself is not affected."
            echo "$now" > "$STATE_DIR/mss.fail"
        fi
    fi
}

found=0
for svc in tunnel.service lbtunnel.service custom_tunnel.service; do
    if [ -f "$UNIT_DIR/$svc" ]; then
        found=1
        check_service "$svc"
    fi
done
for f in "$UNIT_DIR"/multisni-*.service; do
    [ -e "$f" ] || continue
    found=1
    check_service "$(basename "$f")"
done
[ "$found" -eq 1 ] && ensure_mss_clamp
exit 0
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat <<EOF > "$WATCHDOG_SERVICE"
[Unit]
Description=RTT tunnel watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
TimeoutStartSec=45
Nice=10
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
    echo -e "${green}Watchdog v5 installed (checks every 60s; it never restarts a healthy or deliberately stopped tunnel).${rest}"
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

# -------------------------------------------------- start / stop / status
check_tunnel_status() {
    if $SUDO systemctl is-active --quiet tunnel.service; then
        echo -e "${yellow}Multiport is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Multiport is:${red} [Not running]${rest}"
    fi
}

check_lb_tunnel_status() {
    if $SUDO systemctl is-active --quiet lbtunnel.service; then
        echo -e "${yellow}Load balancer is: ${green}[running OK]${rest}"
    else
        echo -e "${yellow}Load balancer is:${red}[Not running]${rest}"
    fi
}

# "Stop" leaves a marker so the watchdog does not undo it (cleared at reboot).
start_tunnel() {
    rm -f "$MANUAL_DIR/tunnel.service.manual_stop"
    $SUDO systemctl restart tunnel.service
    check_tunnel_status
}

stop_tunnel() {
    mkdir -p "$MANUAL_DIR"
    touch "$MANUAL_DIR/tunnel.service.manual_stop"
    $SUDO systemctl stop tunnel.service
    check_tunnel_status
}

start_lb_tunnel() {
    rm -f "$MANUAL_DIR/lbtunnel.service.manual_stop"
    $SUDO systemctl restart lbtunnel.service
    check_lb_tunnel_status
}

stop_lb_tunnel() {
    mkdir -p "$MANUAL_DIR"
    touch "$MANUAL_DIR/lbtunnel.service.manual_stop"
    $SUDO systemctl stop lbtunnel.service
    check_lb_tunnel_status
}

# ---------------------------------------------------------------- uninstall
remove_rtt_service() {   # <unit>
    local svc="$1"
    $SUDO systemctl stop "$svc" 2>/dev/null
    $SUDO systemctl disable "$svc" 2>/dev/null
    $SUDO rm -f "$UNIT_DIR/$svc"
    $SUDO rm -rf "$UNIT_DIR/${svc}.d"
    $SUDO rm -f "$MANUAL_DIR/$svc.manual_stop" "$BACKUP_DIR/$svc.prev"
    $SUDO rm -f "$STATE_DIR/$svc".*
    $SUDO systemctl daemon-reload
    $SUDO systemctl reset-failed 2>/dev/null
}

# RTT (multiport) removes its iptables NAT rules on a clean stop; after a kill
# they can stay behind and keep the whole port range redirected.
nat_leftover_hint() {   # <lport range a-b>
    [ -n "$1" ] || return 0
    local pat="${1/-/:}"
    if iptables -t nat -S 2>/dev/null | grep -Eq -- "--dports? $pat"; then
        echo -e "${yellow}NAT redirect rules for ports $1 are still present (RTT could not clean them up).${rest}"
        echo "They keep those ports redirected to a tunnel that no longer exists."
        if confirm "Flush the NAT table now? (this removes ALL NAT rules on this server)"; then
            iptables -t nat -F
            iptables -t nat -X
            ip6tables -t nat -F 2>/dev/null
            ip6tables -t nat -X 2>/dev/null
            echo "NAT table flushed."
        fi
    fi
}

lb_uninstall() {
    root_access
    local role lport
    if [ ! -f "$UNIT_DIR/lbtunnel.service" ]; then
        echo "The Load-balancer is not installed."
        return
    fi
    role=$(service_role lbtunnel.service)
    lport=$(exec_arg lbtunnel.service --lport)
    remove_rtt_service lbtunnel.service
    [ "$role" == "iran" ] && nat_leftover_hint "$lport"
    if ! other_rtt_services_installed "lbtunnel.service"; then
        $SUDO rm -f "$INSTALL_DIR/RTT" "$INSTALL_DIR/install.sh" 2>/dev/null
    fi
    echo "Uninstallation completed successfully."
}

uninstall() {
    root_access
    local role lport
    if [ ! -f "$UNIT_DIR/tunnel.service" ]; then
        echo "The service is not installed."
        return
    fi
    role=$(service_role tunnel.service)
    lport=$(exec_arg tunnel.service --lport)
    remove_rtt_service tunnel.service
    [ "$role" == "iran" ] && nat_leftover_hint "$lport"
    if ! other_rtt_services_installed "tunnel.service"; then
        $SUDO rm -f "$INSTALL_DIR/RTT" "$INSTALL_DIR/install.sh" 2>/dev/null
    fi
    echo "Uninstallation completed successfully."
}

# ------------------------------------------------------------------- update
update_services() {
    root_access
    local installed latest
    cd "$INSTALL_DIR" || exit 1
    installed=$(rtt_version)
    latest=$(curl -s --max-time 20 "$RTT_LATEST_API" \
        | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^[Vv]//')

    if [ -z "$latest" ]; then
        echo -e "${red}Could not fetch latest version from GitHub API.${rest}"
        return 1
    fi

    if version_gt "$latest" "${installed:-0}"; then
        echo "Updating from ${installed:-unknown} to $latest..."
        # services are stopped while the binary is replaced and always restarted
        if install_rtt; then
            echo -e "${green}Updated to $latest and restarted.${rest}"
        else
            echo -e "${red}Update failed - the previous binary (if any) is still in use.${rest}"
        fi
    else
        echo "Already latest version ($installed)."
    fi
}

install_haproxy() {
    root_access
    detect_distribution
    $SUDO "${package_manager}" install -y haproxy
    echo -e "${green}HAProxy installed.${rest}"
}

# --------------------------------------------------------------------- menu
main() {
    local myip version choice
    myip=$(hostname -I 2>/dev/null | awk '{print $1}')
    version=$(rtt_version)

    clear
    echo -e "${cyan}Radkesvat Fixed By Parham Pahlean (v5.0 Anti-Drop)${rest}"
    echo -e "Your IP is: ${cyan}($myip)${rest}   RTT version: ${cyan}${version:-not installed}${rest}"
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
    echo -e "${yellow} ----------------------------${rest}"
    echo -e "${green}8) Apply ALL stability fixes to the installed tunnel (recommended)${rest}"
    echo -e "${cyan}9) Diagnose connection (links, DNS, kernel, logs)${rest}"
    echo "10) Show tunnel logs"
    echo -e "${purple}18) Re-apply kernel / MSS / service-hardening profile only${rest}"
    echo -e "${cyan}19) Change Tunnel SNI${rest}"
    echo -e "${cyan}20) Change tunnel password${rest}"
    echo -e "${cyan}21) Change IRAN IP (Kharej only)${rest}"
    echo -e "${cyan}22) Set --connection-age (anti-drop switch)${rest}"
    echo -e "${green}24) Reinstall fixed watchdog${rest}"
    echo -e "${cyan}25) Show watchdog log${rest}"
    echo -e "${red}26) Uninstall watchdog${rest}"
    echo -e "${purple}27) Update RTT binary to latest version${rest}"
    echo -e "${purple}28) Install HAProxy (optional)${rest}"
    echo "0) Exit"
    read -r -p "Please choose: " choice

    case $choice in
        1) install ;;
        2) uninstall ;;
        3) start_tunnel ;;
        4) stop_tunnel ;;
        5) check_tunnel_status ;;
        6) load-balancer ;;
        7) lb_uninstall ;;
        8) apply_all_fixes ;;
        9) diagnose ;;
        10) show_logs ;;
        18) root_access; apply_kernel_tuning ;;
        19) change_sni ;;
        20) change_password ;;
        21) change_iran_ip ;;
        22) set_connection_age ;;
        24) install_watchdog ;;
        25) show_watchdog_log ;;
        26) uninstall_watchdog ;;
        27) update_services ;;
        28) install_haproxy ;;
        0) exit ;;
        *) echo "Invalid choice." ;;
    esac
}

main "$@"
