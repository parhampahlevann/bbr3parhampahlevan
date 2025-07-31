#!/bin/bash

set -e

# Configuration Files
CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
DNS_FILE="/etc/systemd/resolved.conf.d/dns.conf"
NETPLAN_DIR="/etc/netplan/"

# Function to display progress messages
show_msg() {
  echo -e "\n[$(date +'%H:%M:%S')] $1"
}

check_root() {
  if [ "$EUID" -ne 0 ]; then 
    show_msg "ERROR: Please run as root: sudo bash $0"
    exit 1
  fi
}

set_dns() {
  show_msg "DNS Configuration:"
  echo "1) Cloudflare (1.1.1.1)"
  echo "2) Google (8.8.8.8)"
  echo "3) OpenDNS (208.67.222.222)"
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
  CURRENT_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null || echo "1500")
  
  show_msg "Current MTU on $INTERFACE: $CURRENT_MTU"
  echo "Recommended values:"
  echo "1) Default (1500)"
  echo "2) Cloud (1450)"
  echo "3) Gaming (1420)"
  echo "4) Custom"
  
  read -p "Select option [1-4]: " mtu_opt
  
  case $mtu_opt in
    1) NEW_MTU=1500 ;;
    2) NEW_MTU=1450 ;;
    3) NEW_MTU=1420 ;;
    4) 
      while true; do
        read -p "Enter MTU value (68-9000): " NEW_MTU
        [ $NEW_MTU -ge 68 ] && [ $NEW_MTU -le 9000 ] && break
        show_msg "Invalid MTU! Must be between 68-9000"
      done
      ;;
    *) show_msg "Invalid option"; return ;;
  esac

  show_msg "Setting MTU to $NEW_MTU on $INTERFACE..."
  ip link set dev $INTERFACE mtu $NEW_MTU
  
  if [ -d "$NETPLAN_DIR" ]; then
    NETPLAN_FILE=$(ls $NETPLAN_DIR/*.yaml 2>/dev/null | head -n1)
    [ -z "$NETPLAN_FILE" ] && NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"
    
    if grep -q "$INTERFACE" $NETPLAN_FILE 2>/dev/null; then
      if grep -q "mtu" $NETPLAN_FILE; then
        sed -i "s/mtu:.*/mtu: $NEW_MTU/" $NETPLAN_FILE
      else
        sed -i "/$INTERFACE:/a \      mtu: $NEW_MTU" $NETPLAN_FILE
      fi
    else
      cat > $NETPLAN_FILE <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: true
      mtu: $NEW_MTU
EOF
    fi
    
    netplan apply
  fi
  
  show_msg "MTU successfully set to $NEW_MTU"
}

optimize_network() {
  MODE=$1
  show_msg "Applying $MODE Optimizations..."

  case $MODE in
    "DOWNLOAD")
      cat > $CONFIG_FILE <<'EOF'
# Download Optimized BBRv3
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_slow_start_after_idle=0
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
EOF
      ;;

    "GAMING")
      cat > $CONFIG_FILE <<'EOF'
# Gaming Optimized BBRv3
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
      ;;

    "STREAM")
      cat > $CONFIG_FILE <<'EOF'
# Streaming Optimized BBRv3
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
EOF
      ;;
  esac

  sysctl --system
  show_msg "$MODE Optimizations Successfully Applied"
}

show_status() {
  clear
  echo "----------------------------------------"
  echo "Current Network Status:"
  echo "----------------------------------------"
  sysctl net.ipv4.tcp_congestion_control | awk '{print "TCP Algorithm: " $3}'
  sysctl net.core.default_qdisc | awk '{print "Queue Discipline: " $3}'
  echo "DNS Servers: $(grep '^DNS=' $DNS_FILE 2>/dev/null | cut -d= -f2 || echo "Not configured")"
  echo "MTU: $(ip link show | grep mtu | head -1 | awk '{print $5}')"
  echo "----------------------------------------"
  read -p "Press Enter to continue..."
}

main_menu() {
  while true; do
    clear
    echo "========================================"
    echo " Ultimate Network Optimizer - BBRv3"
    echo "========================================"
    echo "1) Set DNS Servers"
    echo "2) Set MTU"
    echo "3) Optimize for Download Speed"
    echo "4) Optimize for Gaming (Low Latency)"
    echo "5) Optimize for Streaming"
    echo "6) Show Current Settings"
    echo "0) Exit"
    echo "========================================"
    
    read -p "Select option [0-6]: " opt
    
    case $opt in
      1) set_dns ;;
      2) set_mtu ;;
      3) optimize_network "DOWNLOAD" ;;
      4) optimize_network "GAMING" ;;
      5) optimize_network "STREAM" ;;
      6) show_status ;;
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
show_msg "Starting Network Optimizer..."
main_menu
