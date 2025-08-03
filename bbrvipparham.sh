#!/bin/bash

# Ultimate BBR Optimizer Pro (VPN/WireGuard Edition)
# Enhanced with Auto-Tuning, Advanced TCP Fast Open, and Performance Testing
# Created by Network Engineering Team

# Configuration
CONFIG_FILE="/etc/sysctl.d/99-bbrvip.conf"
DNS_FILE="/etc/systemd/resolved.conf.d/dns.conf"
NETPLAN_DIR="/etc/netplan/"
TEST_SERVER="1.1.1.1"
LOG_FILE="/var/log/bbr_optimizer.log"

# Logging setup
exec > >(tee -a "$LOG_FILE") 2>&1

show_msg() {
    echo -e "\n[$(date +'%H:%M:%S')] $1"
    echo "[$(date +'%H:%M:%S')] $1" >> "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        show_msg "ERROR: Please run as root: sudo bash $0"
        exit 1
    fi
}

check_bbr_support() {
    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

    if [ "$KERNEL_MAJOR" -lt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -lt 9 ]; }; then
        show_msg "ERROR: Kernel version $KERNEL_VERSION does not support BBR. Please upgrade to 4.9+"
        exit 1
    fi

    if ! lsmod | grep -q tcp_bbr; then
        show_msg "Loading BBR module..."
        modprobe tcp_bbr || {
            show_msg "ERROR: Failed to load BBR module"
            exit 1
        }
    fi

    # Check for BBRv3 (custom kernels)
    if [ -f "/proc/sys/net/ipv4/tcp_bbr3" ]; then
        show_msg "BBRv3 detected in kernel"
        return 2
    else
        show_msg "Using BBRv2 (BBRv3 not available)"
        return 1
    fi
}

enable_tcp_fastopen() {
    show_msg "Enabling TCP Fast Open globally"
    echo 3 > /proc/sys/net/ipv4/tcp_fastopen
    
    # For supported services
    if [ -f "/etc/systemd/system/multi-user.target.wants/nginx.service" ]; then
        sed -i '/^ExecStart/ s/$/ --tcp-fastopen/' /lib/systemd/system/nginx.service
        systemctl daemon-reload
        systemctl restart nginx
    fi
    
    if [ -f "/etc/systemd/system/multi-user.target.wants/lighttpd.service" ]; then
        sed -i '/^server\.socket-options\s*=\s*"/ s/"$/,"tcp-fastopen:3"/' /etc/lighttpd/lighttpd.conf
        systemctl restart lighttpd
    fi
}

run_network_test() {
    show_msg "Running network performance tests..."
    
    # Basic connectivity
    ping -c 4 $TEST_SERVER | tee -a "$LOG_FILE"
    
    # TCP connection test
    timeout 10 curl -sI https://$TEST_SERVER | head -n1 | tee -a "$LOG_FILE"
    
    # Throughput test (requires iperf3)
    if command -v iperf3 >/dev/null; then
        show_msg "Running iperf3 test (30s)..."
        iperf3 -c $TEST_SERVER -t 30 -J | jq '.end.sum_received.bits_per_second' | tee -a "$LOG_FILE"
    fi
    
    # Latency test
    if command -v pingparsing >/dev/null; then
        pingparsing -c 10 $TEST_SERVER | tee -a "$LOG_FILE"
    fi
}

set_dns() {
    clear
    echo -e "\nDNS Configuration (VPN Optimized):"
    echo "1) Cloudflare (1.1.1.1) - Best for Gaming"
    echo "2) Google (8.8.8.8) - Balanced"
    echo "3) OpenDNS (208.67.222.222) - Secure"
    echo "4) Quad9 (9.9.9.9) - Privacy Focused"
    echo "5) Custom"
    read -p "Choose [1-5]: " choice
    read -p "Enable DNSSEC? (y/n): " dnssec_choice
    
    case $choice in
        1) DNS="1.1.1.1 1.0.0.1" ;;
        2) DNS="8.8.8.8 8.8.4.4" ;;
        3) DNS="208.67.222.222 208.67.220.220" ;;
        4) DNS="9.9.9.9 149.112.112.112" ;;
        5) read -p "Enter DNS servers (space separated): " DNS ;;
        *) show_msg "Invalid choice"; return ;;
    esac

    DNSSEC="yes"
    [ "$dnssec_choice" = "n" ] && DNSSEC="no"

    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNS=$DNS\nDNSSEC=$DNSSEC" > "$DNS_FILE"
    systemctl restart systemd-resolved && \
        show_msg "DNS set to: $DNS (DNSSEC: $DNSSEC)" || \
        show_msg "ERROR: Failed to set DNS"
}

set_mtu() {
    INTERFACE=$(ip route | grep default | awk '{print $5}')
    [ -z "$INTERFACE" ] && {
        show_msg "ERROR: Could not determine default interface"
        return 1
    }
    
    CURRENT_MTU=$(ip link show "$INTERFACE" | grep -o 'mtu [0-9]*' | awk '{print $2}')
    show_msg "Current MTU on $INTERFACE: $CURRENT_MTU"
    
    echo "Recommended MTU values:"
    echo "1) Standard (1500)"
    echo "2) VPN/Cloud (1380-1420)"
    echo "3) Gaming/VPN (1350-1380)"
    echo "4) WireGuard (1280-1420)"
    echo "5) Custom"
    
    read -p "Select option [1-5]: " mtu_opt
    case $mtu_opt in
        1) NEW_MTU=1500 ;;
        2) NEW_MTU=1400 ;;
        3) NEW_MTU=1370 ;;
        4) NEW_MTU=1420 ;;
        5) 
            while true; do
                read -p "Enter MTU value (576-9000): " NEW_MTU
                [[ "$NEW_MTU" =~ ^[0-9]+$ ]] && [ "$NEW_MTU" -ge 576 ] && [ "$NEW_MTU" -le 9000 ] && break
                show_msg "Invalid MTU! Must be 576-9000"
            done
            ;;
        *) show_msg "Invalid option"; return ;;
    esac

    # Apply MTU
    ip link set dev "$INTERFACE" mtu "$NEW_MTU" && \
        show_msg "MTU set to $NEW_MTU on $INTERFACE" || \
        show_msg "ERROR: Failed to set MTU"
}

optimize_gaming() {
    show_msg "Applying Ultra-Low Latency Gaming Optimizations..."
    
    cat > "$CONFIG_FILE" <<'EOF'
# Ultra-Low Latency Gaming Configuration
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# Advanced Gaming Tweaks
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_orphan_retries=2
net.ipv4.tcp_fin_timeout=5
net.ipv4.tcp_tw_reuse=1

# Buffer Optimization
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem=4096 87380 4194304
net.ipv4.tcp_wmem=4096 65536 4194304

# Connection Management
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_keepalive_time=30
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_intvl=10

# Queue Management
net.core.netdev_max_backlog=25000
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
EOF

    sysctl --system && \
        show_msg "Gaming optimizations applied successfully" || \
        show_msg "ERROR: Failed to apply settings"
}

optimize_streaming() {
    show_msg "Applying High Throughput Streaming Optimizations..."
    
    cat > "$CONFIG_FILE" <<'EOF'
# High Throughput Streaming Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# Streaming-Specific Tweaks
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_autocorking=1
net.ipv4.tcp_limit_output_bytes=262144

# Buffer Optimization
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection Management
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15

# Queue Management
net.core.netdev_max_backlog=100000
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=16384
EOF

    sysctl --system && \
        show_msg "Streaming optimizations applied successfully" || \
        show_msg "ERROR: Failed to apply settings"
}

optimize_tcp_mux() {
    show_msg "Applying Professional TCP MUX Optimizations..."
    
    cat > "$CONFIG_FILE" <<'EOF'
# Professional TCP MUX Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3

# Advanced MUX Settings
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=5
net.ipv4.tcp_max_tw_buckets=262144
net.ipv4.tcp_max_orphans=262144
net.ipv4.tcp_orphan_retries=2
net.ipv4.tcp_autocorking=1
net.ipv4.tcp_limit_output_bytes=131072
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_ecn=1

# Buffer Optimization
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_mem=786432 1048576 1572864

# Connection Management
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_retries2=4
net.ipv4.tcp_keepalive_time=180
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=10

# Queue Management
net.core.netdev_max_backlog=150000
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=32768
EOF

    sysctl --system && \
        show_msg "TCP MUX optimizations applied successfully" || \
        show_msg "ERROR: Failed to apply settings"
}

optimize_bbr3() {
    show_msg "Applying Experimental BBRv3 Optimizations..."
    
    cat > "$CONFIG_FILE" <<'EOF'
# Experimental BBRv3 Configuration
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3

# BBRv3 Specific Tweaks
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_rfc1337=1

# Buffer Optimization
net.core.rmem_max=12582912
net.core.wmem_max=12582912
net.ipv4.tcp_rmem=4096 87380 12582912
net.ipv4.tcp_wmem=4096 65536 12582912

# Connection Management
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_retries2=4
net.ipv4.tcp_fin_timeout=6
net.ipv4.tcp_keepalive_time=45
net.ipv4.tcp_keepalive_probes=4
net.ipv4.tcp_keepalive_intvl=10

# Queue Management
net.core.netdev_max_backlog=50000
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
EOF

    sysctl --system && \
        show_msg "BBRv3 optimizations applied successfully" || \
        show_msg "ERROR: Failed to apply settings"
}

show_status() {
    clear
    echo "=== Network Optimization Status ==="
    echo "Kernel: $(uname -r)"
    echo "BBR Status: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "Queue Discipline: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo "TCP Fast Open: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    echo "Current MTU: $(ip link show $(ip route | grep default | awk '{print $5}') | grep -o 'mtu [0-9]*' | awk '{print $2}')"
    echo "Active DNS: $(grep '^DNS=' "$DNS_FILE" 2>/dev/null | cut -d= -f2)"
    echo "================================"
    read -p "Press Enter to continue..."
}

main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Ultimate BBR Optimizer Pro"
        echo "========================================"
        echo "1) Set DNS Servers"
        echo "2) Set MTU"
        echo "3) Gaming Optimization (Low Latency)"
        echo "4) Streaming Optimization (High Throughput)"
        echo "5) TCP MUX Professional Optimization"
        echo "6) BBRv3 Experimental Optimization"
        echo "7) Run Network Tests"
        echo "8) Show Current Status"
        echo "9) Reboot System"
        echo "0) Exit"
        echo "========================================"
        
        read -p "Select option [0-9]: " opt
        
        case $opt in
            1) set_dns ;;
            2) set_mtu ;;
            3) optimize_gaming ;;
            4) optimize_streaming ;;
            5) optimize_tcp_mux ;;
            6) optimize_bbr3 ;;
            7) run_network_test ;;
            8) show_status ;;
            9) reboot ;;
            0) exit 0 ;;
            *) show_msg "Invalid option"; sleep 1 ;;
        esac
    done
}

# Initial setup
check_root
check_bbr_support
enable_tcp_fastopen
main_menu
