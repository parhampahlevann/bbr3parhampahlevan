#!/bin/bash
# Ultimate Network Optimizer Pro v7.0
# With BBR3 Support & Advanced TCP/VPN Optimizations
# Optimized for Speed, Low Latency and VPN Performance

# Configuration
CONFIG_FILE="/etc/sysctl.d/99-network-opt.conf"
DNS_FILE="/etc/systemd/resolved.conf.d/dns.conf"
GRUB_FILE="/etc/default/grub"
NETPLAN_DIR="/etc/netplan/"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check root
[ "$(id -u)" -ne 0 ] && {
    echo -e "${RED}Please run as root!${NC}"
    exit 1
}

# Check kernel support for BBR3
check_kernel_support() {
    KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
    REQUIRED_VERSION="5.18"
    
    if [ "$(printf '%s\n' "$REQUIRED_VERSION" "$KERNEL_VERSION" | sort -V | head -n1)" != "$REQUIRED_VERSION" ]; then
        echo -e "${YELLOW}Warning: Kernel $KERNEL_VERSION may not support BBR3${NC}"
        echo -e "${YELLOW}Consider upgrading to kernel 5.18+ for full BBR3 support${NC}"
        return 1
    fi
    return 0
}

# Apply Ultimate Optimizations
apply_optimizations() {
    check_kernel_support
    
    # Create optimized configuration
    cat > "$CONFIG_FILE" <<'EOF'
# Ultimate Network Optimizations v7.0
# TCP Fast Open (Enabled for both client and server)
net.ipv4.tcp_fastopen = 3

# TCP MUX Optimizations
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_orphan_retries = 2

# Advanced TCP Settings
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_limit_output_bytes = 131072
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_reordering = 3
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8

# Congestion Control (BBR3 with fallback)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr3
net.ipv4.tcp_congestion_control_backup = bbr

# BBR3 specific settings
net.ipv4.tcp_bbr3_min_rtt_window_sec = 10
net.ipv4.tcp_bbr3_probe_rtt_mode_sec = 5
net.ipv4.tcp_bbr3_pacing_gain = 1.25
net.ipv4.tcp_bbr3_cwnd_gain = 2
net.ipv4.tcp_bbr3_extra_acked_gain = 1.0

# Buffer Optimizations (VPN optimized)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Connection Management
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 100000
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# Additional Optimizations
net.ipv4.ip_no_pmtu_disc = 1
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_challenge_ack_limit = 999999
EOF

    # Apply settings
    sysctl --system >/dev/null 2>&1
    
    # Update GRUB for persistence
    if [ -f "$GRUB_FILE" ]; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash tcp_fastopen=3"/' "$GRUB_FILE"
        update-grub >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}Ultimate optimizations applied with BBR3 support!${NC}"
}

# DNS Configuration (unchanged)
configure_dns() {
    echo -e "\n${YELLOW}Available DNS Providers:${NC}"
    echo "1) Cloudflare (1.1.1.1)"
    echo "2) Google (8.8.8.8)"
    echo "3) OpenDNS (208.67.222.222)"
    echo "4) Quad9 (9.9.9.9)"
    echo "5) Custom"
    echo -n "Select option [1-5]: "
    read choice
    case $choice in
        1) DNS="1.1.1.1 1.0.0.1" ;;
        2) DNS="8.8.8.8 8.8.4.4" ;;
        3) DNS="208.67.222.222 208.67.220.220" ;;
        4) DNS="9.9.9.9 149.112.112.112" ;;
        5)
            echo -n "Enter custom DNS (space separated): "
            read DNS
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            return
            ;;
    esac
    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNS=$DNS\nDNSSEC=allow-downgrade" > "$DNS_FILE"
    systemctl restart systemd-resolved
    echo -e "${GREEN}DNS configured successfully!${NC}"
}

# MTU Optimization with VPN detection
optimize_mtu() {
    INTERFACE=$(ip route | grep default | awk '{print $5}')
    [ -z "$INTERFACE" ] && {
        echo -e "${RED}Could not detect network interface!${NC}"
        return
    }
    CURRENT_MTU=$(ip link show $INTERFACE | grep -o 'mtu [0-9]*' | awk '{print $2}')
    echo -e "\n${YELLOW}Current MTU: ${GREEN}$CURRENT_MTU${NC}"
    
    echo -e "\n${YELLOW}MTU Optimization Options:${NC}"
    echo "1) Auto-detect (Recommended)"
    echo "2) Standard (1500)"
    echo "3) VPN (1400)"
    echo "4) WireGuard (1420)"
    echo "5) Gaming (1350)"
    echo "6) Custom"
    echo -n "Select option [1-6]: "
    read choice
    case $choice in
        1)
            # Auto-detect optimal MTU
            echo -e "${YELLOW}Finding optimal MTU...${NC}"
            MTU=1500
            while [ $MTU -gt 1400 ]; do
                if ping -c 1 -M do -s $((MTU - 28)) 8.8.8.8 >/dev/null 2>&1; then
                    break
                fi
                MTU=$((MTU - 10))
            done
            echo -e "${GREEN}Optimal MTU: $MTU${NC}"
            NEW_MTU=$MTU
            ;;
        2) NEW_MTU=1500 ;;
        3) NEW_MTU=1400 ;;
        4) NEW_MTU=1420 ;;
        5) NEW_MTU=1350 ;;
        6)
            echo -n "Enter MTU value (576-9000): "
            read NEW_MTU
            [[ ! $NEW_MTU =~ ^[0-9]+$ ]] || [ $NEW_MTU -lt 576 ] || [ $NEW_MTU -gt 9000 ] && {
                echo -e "${RED}Invalid MTU value!${NC}"
                return
            }
            ;;
        *)
            echo -e "${RED}Invalid choice!${NC}"
            return
            ;;
    esac
    
    # Apply temporary MTU
    ip link set dev $INTERFACE mtu $NEW_MTU || {
        echo -e "${RED}Failed to set MTU!${NC}"
        return
    }
    
    # Make permanent in Netplan
    NETPLAN_FILE=$(find $NETPLAN_DIR -name "*.yaml" -o -name "*.yml" | head -n1)
    [ -z "$NETPLAN_FILE" ] && NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"
    
    if [ -f "$NETPLAN_FILE" ]; then
        if grep -q "$INTERFACE:" "$NETPLAN_FILE"; then
            if grep -q "mtu:" "$NETPLAN_FILE"; then
                sed -i "/$INTERFACE:/,/mtu:/s/mtu:.*/mtu: $NEW_MTU/" "$NETPLAN_FILE"
            else
                sed -i "/$INTERFACE:/a \      mtu: $NEW_MTU" "$NETPLAN_FILE"
            fi
        else
            echo -e "network:\n  version: 2\n  ethernets:\n    $INTERFACE:\n      mtu: $NEW_MTU" >> "$NETPLAN_FILE"
        fi
    else
        echo -e "network:\n  version: 2\n  ethernets:\n    $INTERFACE:\n      mtu: $NEW_MTU" > "$NETPLAN_FILE"
    fi
    
    netplan apply >/dev/null 2>&1
    echo -e "${GREEN}MTU optimized to $NEW_MTU!${NC}"
}

# Test Network Performance
test_network_performance() {
    echo -e "\n${BLUE}=== Network Performance Test ===${NC}"
    
    # Test BBR status
    echo -e "${YELLOW}Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
    lsmod | grep -q bbr && echo -e "${GREEN}BBR module loaded${NC}" || echo -e "${RED}BBR module not loaded${NC}"
    
    # Test basic connectivity
    echo -e "${YELLOW}Testing latency...${NC}"
    ping -c 4 8.8.8.8 | tail -1 | awk '{print "Average Latency:", $4}'
    
    # Test download speed (requires curl)
    if command -v curl >/dev/null; then
        echo -e "${YELLOW}Testing download speed...${NC}"
        curl -s -o /dev/null -w "Download Speed: %{speed_download} bytes/sec\n" https://proof.ovh.net/files/100Mb.dat
    fi
    
    # Test bufferbloat (requires netperf)
    if command -v netperf >/dev/null; then
        echo -e "${YELLOW}Testing bufferbloat...${NC}"
        netperf -H localhost -t TCP_RR -l 10 -- -O min_latency,mean_latency,max_latency,stddev_latency
    fi
    
    echo -e "${BLUE}=============================${NC}"
}

# Status Check
show_status() {
    echo -e "\n${BLUE}=== Current Network Status ===${NC}"
    echo -e "${YELLOW}TCP Algorithm:${NC} $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "${YELLOW}Queue Discipline:${NC} $(sysctl -n net.core.default_qdisc)"
    echo -e "${YELLOW}TCP Fast Open:${NC} $(sysctl -n net.ipv4.tcp_fastopen)"
    
    INTERFACE=$(ip route | grep default | awk '{print $5}')
    [ -n "$INTERFACE" ] && {
        echo -e "${YELLOW}Interface:${NC} $INTERFACE"
        echo -e "${YELLOW}MTU:${NC} $(ip link show $INTERFACE | grep -o 'mtu [0-9]*' | awk '{print $2}')"
    }
    
    echo -e "${YELLOW}DNS:${NC} $(grep '^DNS=' "$DNS_FILE" 2>/dev/null | cut -d= -f2 || echo 'System Default')"
    echo -e "${BLUE}=============================${NC}"
}

# Main Menu
while true; do
    clear
    echo -e "${BLUE}=== Network Optimizer Pro v7.0 ===${NC}"
    echo "1. Apply Ultimate Optimizations (BBR3)"
    echo "2. Configure DNS"
    echo "3. Optimize MTU"
    echo "4. Show Current Status"
    echo "5. Test Network Performance"
    echo "6. Exit"
    echo -n "Select option [1-6]: "
    read choice
    case $choice in
        1) apply_optimizations ;;
        2) configure_dns ;;
        3) optimize_mtu ;;
        4) show_status ;;
        5) test_network_performance ;;
        6) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
    
    echo
    read -p "Press Enter to continue..."
done
