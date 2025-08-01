#!/bin/bash

# Ultimate BBR Optimizer Script (Updated for VPN with BBRv2/BBRv3)
# Supports Gaming, Streaming, Balanced, Professional TCP MUX, and BBRv3 modes
# Optimized for VPN environments by Grok Analysis

# Configuration Files
CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
DNS_FILE="/etc/systemd/resolved.conf.d/dns.conf"
NETPLAN_DIR="/etc/netplan/"

show_msg() {
    echo -e "\n[$(date +'%H:%M:%S')] $1"
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
        show_msg "ERROR: Kernel version $KERNEL_VERSION does not support BBR. Please upgrade to 4.9 or higher."
        exit 1
    fi

    if ! lsmod | grep -q tcp_bbr; then
        show_msg "WARNING: BBR module not loaded. Attempting to load..."
        modprobe tcp_bbr || {
            show_msg "ERROR: Failed to load BBR module."
            exit 1
        }
    fi

    show_msg "BBR module loaded. Note: BBRv3 requires custom kernel; using BBRv2 if unavailable."
}

set_dns() {
    clear
    echo -e "\nDNS Configuration (Optimized for VPN):"
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
    [ "$dnssec_choice" = "n" ] || [ "$dnssec_choice" = "N" ] && DNSSEC="no"

    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNS=$DNS\nDNSSEC=$DNSSEC" > "$DNS_FILE"
    systemctl restart systemd-resolved
    show_msg "DNS set to: $DNS (DNSSEC: $DNSSEC)"
}

set_mtu() {
    INTERFACE=$(ip route | grep default | awk '{print $5}' 2>/dev/null)
    if [ -z "$INTERFACE" ]; then
        show_msg "ERROR: Could not determine default network interface"
        return 1
    fi
    
    CURRENT_MTU=$(cat /sys/class/net/"$INTERFACE"/mtu 2>/dev/null || echo "1500")
    
    show_msg "Current MTU on $INTERFACE: $CURRENT_MTU"
    echo "Recommended values for VPN:"
    echo "1) Default (1500) - General use"
    echo "2) VPN/Cloud (1420) - Common for VPNs"
    echo "3) Gaming/VPN (1380) - Low latency with VPN overhead"
    echo "4) Custom"
    
    while true; do
        read -rp "Select option [1-4]: " mtu_opt
        case $mtu_opt in
            1) NEW_MTU=1500; break ;;
            2) NEW_MTU=1420; break ;;
            3) NEW_MTU=1380; break ;;
            4) 
                while true; do
                    read -rp "Enter MTU value (576-9000): " NEW_MTU
                    if [[ "$NEW_MTU" =~ ^[0-9]+$ ]] && [ "$NEW_MTU" -ge 576 ] && [ "$NEW_MTU" -le 9000 ]; then
                        break
                    fi
                    show_msg "Invalid MTU! Must be between 576-9000"
                done
                break
                ;;
            *) show_msg "Invalid option" ;;
        esac
    done

    # Check if MTU is supported by interface
    show_msg "Testing MTU $NEW_MTU on $INTERFACE..."
    if ! ip link set dev "$INTERFACE" mtu "$NEW_MTU" >/dev/null 2>&1; then
        show_msg "ERROR: MTU $NEW_MTU not supported by $INTERFACE. Reverting to $CURRENT_MTU."
        return 1
    fi

    # Test MTU with ping to avoid fragmentation
    TEST_IP="8.8.8.8"
    show_msg "Testing MTU with ping to $TEST_IP..."
    if ping -c 1 -s $((NEW_MTU - 28)) -M do "$TEST_IP" >/dev/null 2>&1; then
        show_msg "MTU test passed"
    else
        show_msg "WARNING: MTU $NEW_MTU may cause fragmentation. Consider a lower value."
        ip link set dev "$INTERFACE" mtu "$CURRENT_MTU"
        return 1
    fi

    # Make MTU persistent in Netplan
    mkdir -p "$NETPLAN_DIR"
    NETPLAN_FILE=$(find "$NETPLAN_DIR" -name "*.yaml" -o -name "*.yml" | head -n 1)
    [ -z "$NETPLAN_FILE" ] && NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"

    # Create backup
    [ -f "$NETPLAN_FILE" ] && cp "$NETPLAN_FILE" "$NETPLAN_FILE.bak"

    if [ ! -f "$NETPLAN_FILE" ]; then
        cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: true
      mtu: $NEW_MTU
EOF
    else
        if ! grep -q "$INTERFACE:" "$NETPLAN_FILE"; then
            echo "    $INTERFACE:" >> "$NETPLAN_FILE"
            echo "      dhcp4: true" >> "$NETPLAN_FILE"
            echo "      mtu: $NEW_MTU" >> "$NETPLAN_FILE"
        else
            if grep -q "mtu:" "$NETPLAN_FILE"; then
                sed -i "/$INTERFACE:/,/mtu:/s/mtu:.*/mtu: $NEW_MTU/" "$NETPLAN_FILE"
            else
                sed -i "/$INTERFACE:/a \      mtu: $NEW_MTU" "$NETPLAN_FILE"
            fi
        fi
    fi

    if netplan apply >/dev/null 2>&1; then
        show_msg "MTU $NEW_MTU applied and saved persistently"
    else
        show_msg "ERROR: Failed to apply netplan changes. Restoring backup..."
        [ -f "$NETPLAN_FILE.bak" ] && mv "$NETPLAN_FILE.bak" "$NETPLAN_FILE"
        netplan apply
        return 1
    fi
}

optimize_network() {
    MODE=$1
    show_msg "Applying $MODE Optimizations..."

    case $MODE in
        "GAMING")
            cat > "$CONFIG_FILE" <<'EOF'
# Ultra-Low Latency BBR Configuration for Gaming (VPN Optimized)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# Buffer settings for low latency
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 87380 8388608
net.ipv4.tcp_wmem=4096 65536 8388608

# Connection stability for VPN
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_fin_timeout=7
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=10

# Queue management
net.core.netdev_max_backlog=50000
net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
EOF
            ;;

        "STREAM")
            cat > "$CONFIG_FILE" <<'EOF'
# High Throughput BBR Configuration for Streaming (VPN Optimized)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# Buffer settings for high throughput
net.core.rmem_max=25165824
net.core.wmem_max=25165824
net.ipv4.tcp_rmem=4096 87380 25165824
net.ipv4.tcp_wmem=4096 65536 25165824

# Connection stability for VPN
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=30

# Queue management
net.core.netdev_max_backlog=100000
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
EOF
            ;;

        "BALANCED")
            cat > "$CONFIG_FILE" <<'EOF'
# Balanced BBR Configuration (VPN Optimized)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# Buffer settings
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection stability for VPN
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=90
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15

# Queue management
net.core.netdev_max_backlog=75000
net.core.somaxconn=49152
net.ipv4.tcp_max_syn_backlog=12288
EOF
            ;;

        "MUX")
            cat > "$CONFIG_FILE" <<'EOF'
# Professional TCP MUX Configuration with BBR (VPN Optimized)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Advanced Multiplexing settings for VPN
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=5
net.ipv4.tcp_max_tw_buckets=131072
net.ipv4.tcp_max_orphans=131072
net.ipv4.tcp_orphan_retries=2

# Advanced congestion control for MUX
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_autocorking=1
net.ipv4.tcp_limit_output_bytes=131072

# Buffer settings for MUX
net.core.rmem_max=25165824
net.core.wmem_max=25165824
net.ipv4.tcp_rmem=4096 87380 25165824
net.ipv4.tcp_wmem=4096 65536 25165824
net.ipv4.tcp_mem=786432 1048576 1572864

# Advanced queue and connection settings
net.core.netdev_max_backlog=150000
net.core.somaxconn=65536
net.ipv4.tcp_max_syn_backlog=32768
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2

# Keepalive settings for stable VPN connections
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15

# Standard TCP settings
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
EOF
            ;;

        "BBR3")
            cat > "$CONFIG_FILE" <<'EOF'
# Experimental BBRv3 Configuration (VPN Optimized)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Advanced BBRv3 settings for VPN
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# Buffer settings for BBRv3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection stability for VPN
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=90
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_keepalive_intvl=15

# Queue management
net.core.netdev_max_backlog=100000
net.core.somaxconn=49152
net.ipv4.tcp_max_syn_backlog=16384
EOF
            ;;
    esac

    sysctl --system >/dev/null 2>&1
    show_msg "$MODE Optimizations Successfully Applied"
}

show_status() {
    clear
    INTERFACE=$(ip route | grep default | awk '{print $5}' 2>/dev/null || echo "Unknown")
    CURRENT_MTU=$(cat /sys/class/net/"$INTERFACE"/mtu 2>/dev/null || echo "Unknown")
    
    echo "----------------------------------------"
    echo "Current Network Status:"
    echo "----------------------------------------"
    echo "TCP Algorithm: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "Unknown")"
    echo "Queue Discipline: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo "Unknown")"
    echo "Interface: $INTERFACE"
    echo "MTU: $CURRENT_MTU"
    echo "DNS Servers: $(grep '^DNS=' "$DNS_FILE" 2>/dev/null | cut -d= -f2 || echo "Not configured")"
    echo "----------------------------------------"
    
    if grep -q "tcp_tw_reuse=1" "$CONFIG_FILE" 2>/dev/null; then
        echo "TCP MUX Features:"
        echo "TIME-WAIT Reuse: Enabled"
        echo "Max TW Buckets: $(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo "Unknown")"
        echo "Max Orphans: $(sysctl -n net.ipv4.tcp_max_orphans 2>/dev/null || echo "Unknown")"
        echo "Autocorking: $(sysctl -n net.ipv4.tcp_autocorking 2>/dev/null || echo "Unknown")"
        echo "----------------------------------------"
    fi
    
    read -rp "Press Enter to continue..."
}

reboot_system() {
    read -rp "Are you sure you want to reboot? (y/n): " choice
    case "$choice" in
        y|Y) 
            show_msg "System will reboot in 5 seconds..."
            sleep 5
            reboot
            ;;
        *)
            show_msg "Reboot cancelled"
            ;;
    esac
}

main_menu() {
    while true; do
        clear
        echo "========================================"
        echo " Ultimate BBR Optimizer (VPN Edition)"
        echo "========================================"
        echo "1) Set DNS Servers"
        echo "2) Set MTU"
        echo "3) Optimize for Gaming (Ultra-Low Latency)"
        echo "4) Optimize for Streaming (High Throughput)"
        echo "5) Balanced Optimization"
        echo "6) Professional TCP MUX Optimization"
        echo "7) Experimental BBRv3 Optimization"
        echo "8) Show Current Settings"
        echo "9) Reboot System"
        echo "0) Exit"
        echo "========================================"
        
        read -rp "Select option [0-9]: " opt
        
        case $opt in
            1) set_dns ;;
            2) set_mtu ;;
            3) optimize_network "GAMING" ;;
            4) optimize_network "STREAM" ;;
            5) optimize_network "BALANCED" ;;
            6) optimize_network "MUX" ;;
            7) optimize_network "BBR3" ;;
            8) show_status ;;
            9) reboot_system ;;
            0) exit 0 ;;
            *)
                show_msg "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Initial checks
check_root
show_msg "Starting Ultimate BBR Optimizer (VPN Edition)..."
check_bbr_support
main_menu
