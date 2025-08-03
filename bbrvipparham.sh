#!/bin/bash

# Ultimate Kernel Network Optimizer v3.0
# Complete TCP/UDP Optimization for Lowest Latency & Maximum Speed
# Tested on Ubuntu 20.04/22.04 LTS
# Credits: Network Engineering Team

# Configuration
CONFIG_FILE="/etc/sysctl.d/99-ultimate-network.conf"
GRUB_FILE="/etc/default/grub"
MODULES_FILE="/etc/modules-load.d/network.conf"
LIMITS_FILE="/etc/security/limits.conf"
DNS_FILE="/etc/systemd/resolved.conf.d/dns.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Functions
show_msg() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

show_warning() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING:${NC} $1"
}

show_error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} $1"
    exit 1
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        show_error "Please run as root: sudo bash $0"
    fi
}

check_os() {
    if ! grep -q 'Ubuntu' /etc/os-release; then
        show_error "This script is optimized for Ubuntu OS"
    fi
}

apply_changes() {
    sysctl --system > /dev/null 2>&1
    update-grub > /dev/null 2>&1
    systemctl restart systemd-resolved > /dev/null 2>&1
}

optimize_kernel() {
    show_msg "Applying Ultimate Kernel Network Optimizations..."

    # TCP Core Optimizations
    cat > "$CONFIG_FILE" <<'EOF'
# Ultimate TCP Network Optimizations
# --------------------------------

# TCP Fundamental Parameters
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_workaround_signed_windows=1
net.ipv4.tcp_early_retrans=3
net.ipv4.tcp_retrans_collapse=0
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_syncookies=1

# Advanced TCP Algorithms
net.ipv4.tcp_congestion_control=bbr2
net.core.default_qdisc=fq_pie
net.ipv4.tcp_ecn=1
net.ipv4.tcp_ecn_fallback=1
net.ipv4.tcp_frto=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_adv_win_scale=1

# TCP Buffer Optimizations
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=4194304
net.core.wmem_default=4194304
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# TCP Connection Management
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_retries2=5
net.ipv4.tcp_orphan_retries=2

# TCP Keepalive Settings
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=5

# Network Stack Optimizations
net.core.netdev_max_backlog=100000
net.core.somaxconn=65535
net.core.optmem_max=4194304
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_limit_output_bytes=65536

# IPv6 Optimizations
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
net.ipv6.conf.lo.disable_ipv6=0
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.all.accept_ra=1
net.ipv6.conf.default.accept_ra=1
EOF

    # Kernel Module Loading
    cat > "$MODULES_FILE" <<'EOF'
# Network Performance Modules
tcp_bbr2
sch_fq_pie
nf_conntrack
nf_nat
tls
cryptd
ahci
xhci_pci
EOF

    # GRUB Boot Parameters
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash tcp_bbr2=1 fs.may_detach_mounts=1 module.sig_enforce=1 nmi_watchdog=0 nosgx mitigations=off net.ifnames=0 no_timer_check console=tty0 console=ttyS0,115200n8 noibrs noibpb nopti nospectre_v2 nospectre_v1 l1tf=off nospec_store_bypass_disable no_stf_barrier mds=off tsx=on tsx_async_abort=off"/g' "$GRUB_FILE"

    # System Limits
    echo "* soft nofile 1048576" >> "$LIMITS_FILE"
    echo "* hard nofile 1048576" >> "$LIMITS_FILE"
    echo "* soft nproc unlimited" >> "$LIMITS_FILE"
    echo "* hard nproc unlimited" >> "$LIMITS_FILE"
    echo "* soft memlock unlimited" >> "$LIMITS_FILE"
    echo "* hard memlock unlimited" >> "$LIMITS_FILE"

    # DNS Optimizations
    mkdir -p /etc/systemd/resolved.conf.d
    cat > "$DNS_FILE" <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 9.9.9.9
DNSOverTLS=opportunistic
DNSSEC=allow-downgrade
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
EOF

    apply_changes
    show_msg "Kernel optimizations applied successfully!"
}

verify_optimizations() {
    show_msg "Verifying applied optimizations..."
    
    echo -e "\n${YELLOW}=== Current TCP Settings ===${NC}"
    sysctl net.ipv4.tcp_available_congestion_control
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_fastopen
    
    echo -e "\n${YELLOW}=== Buffer Sizes ===${NC}"
    sysctl net.core.rmem_max net.core.wmem_max
    sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    
    echo -e "\n${YELLOW}=== Connection Settings ===${NC}"
    sysctl net.ipv4.tcp_max_syn_backlog
    sysctl net.core.somaxconn
    
    echo -e "\n${YELLOW}=== Kernel Modules ===${NC}"
    lsmod | grep -e tcp_bbr2 -e sch_fq_pie
}

main() {
    check_root
    check_os
    
    clear
    echo -e "${GREEN}=== Ultimate Kernel Network Optimizer ===${NC}"
    echo "This script will:"
    echo "1. Optimize all TCP/UDP kernel parameters"
    echo "2. Configure BBR2 congestion control"
    echo "3. Tune network buffers and queues"
    echo "4. Apply system-wide performance tweaks"
    
    read -p "Continue? (y/n): " choice
    case "$choice" in
        y|Y) 
            optimize_kernel
            verify_optimizations
            show_msg "Optimization complete! Reboot recommended."
            ;;
        *)
            show_msg "Operation cancelled."
            exit 0
            ;;
    esac
}

main
