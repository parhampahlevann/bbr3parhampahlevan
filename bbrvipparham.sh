#!/bin/bash

set -e

# Configuration Files
CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
DNS_FILE="/etc/systemd/resolved.conf.d/dns.conf"
NETPLAN_DIR="/etc/netplan/"

show_msg() {
    echo -e "\n[$(date +'%H:%M:%S')] $1"
}

check_root() {
    [ "$EUID" -ne 0 ] && show_msg "ERROR: Please run as root: sudo bash $0" && exit 1
}

set_dns() {
    clear
    echo -e "\nDNS Configuration:"
    echo "1) Cloudflare (1.1.1.1) - Best for Gaming"
    echo "2) Google (8.8.8.8) - Balanced"
    echo "3) OpenDNS (208.67.222.222) - Secure"
    echo "4) Custom"
    read -p "Choose [1-4]: " choice
    
    case $choice in
        1) DNS="1.1.1.1 1.0.0.1" ;;
        2) DNS="8.8.8.8 8.8.4.4" ;;
        3) DNS="208.67.222.222 208.67.220.220" ;;
        4) read -p "Enter DNS servers (space separated): " DNS ;;
        *) show_msg "Invalid choice"; return ;;
    esac

    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNS=$DNS\nDNSSEC=no" > $DNS_FILE
    systemctl restart systemd-resolved
    show_msg "DNS set to: $DNS"
}

set_mtu() {
    INTERFACE=$(ip route | grep default | awk '{print $5}')
    if [ -z "$INTERFACE" ]; then
        show_msg "ERROR: Could not determine default network interface"
        return 1
    fi
    
    CURRENT_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null || echo "1500")
    
    show_msg "Current MTU on $INTERFACE: $CURRENT_MTU"
    echo "Recommended values:"
    echo "1) Default (1500) - General use"
    echo "2) Cloud (1450) - VPN/Cloud"
    echo "3) Gaming (1420) - Low latency"
    echo "4) Custom"
    
    while true; do
        read -p "Select option [1-4]: " mtu_opt
        case $mtu_opt in
            1) NEW_MTU=1500; break ;;
            2) NEW_MTU=1450; break ;;
            3) NEW_MTU=1420; break ;;
            4) 
                while true; do
                    read -p "Enter MTU value (576-9000): " NEW_MTU
                    [[ $NEW_MTU =~ ^[0-9]+$ ]] && [ $NEW_MTU -ge 576 ] && [ $NEW_MTU -le 9000 ] && break
                    show_msg "Invalid MTU! Must be between 576-9000"
                done
                break
                ;;
            *) show_msg "Invalid option" ;;
        esac
    done

    # Apply MTU immediately
    show_msg "Setting MTU to $NEW_MTU on $INTERFACE..."
    if ! ip link set dev $INTERFACE mtu $NEW_MTU; then
        show_msg "ERROR: Failed to set MTU. Interface may not support this value."
        return 1
    fi

    # Make MTU persistent in Netplan
    mkdir -p $NETPLAN_DIR
    NETPLAN_FILE=$(ls $NETPLAN_DIR/*.yaml 2>/dev/null | head -n1)
    [ -z "$NETPLAN_FILE" ] && NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"

    # Create backup
    [ -f "$NETPLAN_FILE" ] && cp "$NETPLAN_FILE" "$NETPLAN_FILE.bak"

    # Create new config if doesn't exist
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
        # Check if interface exists in config
        if ! grep -q "$INTERFACE:" "$NETPLAN_FILE"; then
            # Add new interface config
            cat >> "$NETPLAN_FILE" <<EOF
    $INTERFACE:
      dhcp4: true
      mtu: $NEW_MTU
EOF
        else
            # Update existing MTU
            if grep -q "mtu:" "$NETPLAN_FILE"; then
                sed -i "/$INTERFACE:/,/mtu:/s/mtu:.*/mtu: $NEW_MTU/" "$NETPLAN_FILE"
            else
                sed -i "/$INTERFACE:/a \      mtu: $NEW_MTU" "$NETPLAN_FILE"
            fi
        fi
    fi

    # Apply netplan changes
    if netplan apply; then
        show_msg "MTU successfully set to $NEW_MTU (persistent after reboot)"
    else
        show_msg "ERROR: Failed to apply netplan changes. Restoring backup..."
        [ -f "$NETPLAN_FILE.bak" ] && mv "$NETPLAN_FILE.bak" "$NETPLAN_FILE"
        netplan apply
        return 1
    fi
    
    # Verify MTU was actually changed
    ACTUAL_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null)
    if [ "$ACTUAL_MTU" != "$NEW_MTU" ]; then
        show_msg "WARNING: MTU shows as $ACTUAL_MTU but should be $NEW_MTU. Reboot may be needed."
    else
        show_msg "MTU successfully verified as $NEW_MTU"
    fi
}

optimize_network() {
    MODE=$1
    show_msg "Applying $MODE Optimizations..."

    case $MODE in
        "GAMING")
            cat > $CONFIG_FILE <<'EOF'
# Ultra-Low Latency BBRv3 Configuration for Gaming
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1

# Buffer settings for low latency
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Connection stability
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
            cat > $CONFIG_FILE <<'EOF'
# High Throughput BBRv3 Configuration for Streaming
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_slow_start_after_idle=0

# Buffer settings for high throughput
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432

# Connection stability
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
            cat > $CONFIG_FILE <<'EOF'
# Balanced BBRv3 Configuration
net.core.default_qdisc=fq_pie
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
net.core.rmem_max=25165824
net.core.wmem_max=25165824
net.ipv4.tcp_rmem=4096 87380 25165824
net.ipv4.tcp_wmem=4096 65536 25165824

# Connection stability
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
    esac

    sysctl --system
    show_msg "$MODE Optimizations Successfully Applied"
}

show_status() {
    clear
    INTERFACE=$(ip route | grep default | awk '{print $5}' 2>/dev/null || echo "Unknown")
    CURRENT_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null || echo "Unknown")
    
    echo "----------------------------------------"
    echo "Current Network Status:"
    echo "----------------------------------------"
    echo "TCP Algorithm: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "Unknown")"
    echo "Queue Discipline: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo "Unknown")"
    echo "Interface: $INTERFACE"
    echo "MTU: $CURRENT_MTU"
    echo "DNS Servers: $(grep '^DNS=' $DNS_FILE 2>/dev/null | cut -d= -f2 || echo "Not configured")"
    echo "----------------------------------------"
    read -p "Press Enter to continue..."
}

reboot_system() {
    read -p "Are you sure you want to reboot? (y/n): " choice
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
        echo " Ultimate BBRv3 Optimizer for Gaming/Streaming"
        echo "========================================"
        echo "1) Set DNS Servers"
        echo "2) Set MTU"
        echo "3) Optimize for Gaming (Ultra-Low Latency)"
        echo "4) Optimize for Streaming (High Throughput)"
        echo "5) Balanced Optimization"
        echo "6) Show Current Settings"
        echo "7) Reboot System"
        echo "0) Exit"
        echo "========================================"
        
        read -p "Select option [0-7]: " opt
        
        case $opt in
            1) set_dns ;;
            2) set_mtu ;;
            3) optimize_network "GAMING" ;;
            4) optimize_network "STREAM" ;;
            5) optimize_network "BALANCED" ;;
            6) show_status ;;
            7) reboot_system ;;
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
show_msg "Starting Ultimate BBRv3 Optimizer..."
main_menu
