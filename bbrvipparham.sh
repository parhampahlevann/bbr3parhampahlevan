#!/bin/bash

set -e

# Configuration Files
CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
DNS_CONFIG="/etc/systemd/resolved.conf"
NETPLAN_CONFIG="/etc/netplan/01-netcfg.yaml"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo bash $0)"
    exit 1
  fi
}

show_menu() {
  clear
  echo "=============================================="
  echo " Ultimate Network Optimizer - BBRv3 + Advanced"
  echo "=============================================="
  echo "1) Install BBRv3 (Auto Tuned)"
  echo "2) Set Custom DNS"
  echo "3) Set Custom MTU"
  echo "4) Apply All Optimizations"
  echo "5) Reboot System"
  echo "6) View Current Settings"
  echo "0) Exit"
  echo "=============================================="
  read -rp "Select option [0-6]: " opt
}

optimize_bbr() {
  cat > "$CONFIG_FILE" <<'EOF'
# BBRv3 Optimized Settings
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Buffer Optimization
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Latency Reduction
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Connection Stability
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_fin_timeout = 15
EOF

  sysctl --system
  echo "✅ BBRv3 Optimizations Applied (Persistent)"
}

set_dns() {
  echo "🌐 Available DNS Providers:"
  echo "1) Cloudflare (1.1.1.1)"
  echo "2) Google (8.8.8.8)"
  echo "3) OpenDNS (208.67.222.222)"
  echo "4) Custom"
  read -rp "Select DNS provider [1-4]: " dns_opt

  case $dns_opt in
    1) DNS_SERVERS="1.1.1.1 1.0.0.1" ;;
    2) DNS_SERVERS="8.8.8.8 8.8.4.4" ;;
    3) DNS_SERVERS="208.67.222.222 208.67.220.220" ;;
    4) read -rp "Enter custom DNS (space separated): " DNS_SERVERS ;;
    *) echo "Invalid option"; return ;;
  esac

  # Configure systemd-resolved
  sed -i '/^DNS=/d' "$DNS_CONFIG"
  echo "DNS=$DNS_SERVERS" >> "$DNS_CONFIG"
  echo "FallbackDNS=9.9.9.9 149.112.112.112" >> "$DNS_CONFIG"
  echo "DNSSEC=allow-downgrade" >> "$DNS_CONFIG"

  systemctl restart systemd-resolved
  echo "✅ DNS Configured: $DNS_SERVERS (Persistent)"
}

set_mtu() {
  read -rp "Enter MTU size (default 1500): " MTU_SIZE
  MTU_SIZE=${MTU_SIZE:-1500}

  # Find active interface
  INTERFACE=$(ip route | grep default | awk '{print $5}')

  # Configure Netplan
  if [ -f "$NETPLAN_CONFIG" ]; then
    if ! grep -q "mtu" "$NETPLAN_CONFIG"; then
      sed -i "/$INTERFACE:/a \      mtu: $MTU_SIZE" "$NETPLAN_CONFIG"
    else
      sed -i "s/mtu:.*/mtu: $MTU_SIZE/" "$NETPLAN_CONFIG"
    fi
    netplan apply
  else
    ip link set dev "$INTERFACE" mtu "$MTU_SIZE"
    echo "⚠️ Netplan not found, MTU set temporarily (add to network config)"
  fi

  echo "✅ MTU set to $MTU_SIZE on $INTERFACE"
}

apply_all() {
  optimize_bbr
  set_dns
  set_mtu
  echo "🚀 All optimizations applied successfully!"
}

reboot_system() {
  read -rp "Are you sure you want to reboot? [y/N]: " choice
  case "$choice" in
    y|Y) 
      echo "🔄 Rebooting system..."
      reboot
      ;;
    *) 
      echo "Reboot cancelled."
      ;;
  esac
}

show_status() {
  echo "📊 Current Network Settings:"
  echo "---------------------------"
  echo "BBR Status: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
  echo "Queue Discipline: $(sysctl net.core.default_qdisc | awk '{print $3}')"
  echo "DNS Servers: $(grep "^DNS=" "$DNS_CONFIG" 2>/dev/null || echo "Not Configured")"
  echo "MTU Size: $(ip link show | grep mtu | head -1 | awk '{print $5}')"
  echo "---------------------------"
  read -rp "Press Enter to continue..."
}

main() {
  check_root
  while true; do
    show_menu
    case $opt in
      1) optimize_bbr ;;
      2) set_dns ;;
      3) set_mtu ;;
      4) apply_all ;;
      5) reboot_system ;;
      6) show_status ;;
      0) 
        echo "Exiting..."
        exit 0
        ;;
      *) 
        echo "Invalid option"
        sleep 1
        ;;
    esac
  done
}

main
