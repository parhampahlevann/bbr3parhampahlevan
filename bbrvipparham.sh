#!/bin/bash

set -e

CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"

optimize_network() {
  echo "🔧 Applying optimized settings for low jitter and high speed..."
  
  cat > "$CONFIG_FILE" <<'EOF'
# Basic BBRv3 Configuration
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Balanced Buffer Sizes (for stability)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Jitter Reduction
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_low_latency = 1

# Connection Stability
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fin_timeout = 15

# Queue Management
net.core.netdev_max_backlog = 30000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192

# Advanced Options
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
EOF

  # Apply settings
  sysctl --system
  echo "✅ Optimization applied successfully!"
}

rollback_settings() {
  echo "🔄 Rolling back to default settings..."
  
  cat > "$CONFIG_FILE" <<'EOF'
# Default TCP Settings
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = cubic

# Default Buffer Sizes
net.core.rmem_max = 212992
net.core.wmem_max = 212992
net.ipv4.tcp_rmem = 4096 131072 6291456
net.ipv4.tcp_wmem = 4096 16384 4194304

# Default Queue Settings
net.core.netdev_max_backlog = 1000
net.core.somaxconn = 4096
EOF

  sysctl --system
  echo "✔️ Successfully rolled back to default settings"
}

monitor_network() {
  echo "📊 Running network diagnostics..."
  ping -c 10 google.com | grep rtt
  tc -s qdisc show
  ss -tin
}

main_menu() {
  while true; do
    echo ""
    echo "==== Network Optimization Menu ===="
    echo "1) Apply Low-Jitter BBRv3 Settings"
    echo "2) Rollback to Default Settings"
    echo "3) Monitor Network Performance"
    echo "0) Exit"
    echo "================================"
    read -rp "Select option [0-3]: " opt

    case "$opt" in
      1) optimize_network ;;
      2) rollback_settings ;;
      3) monitor_network ;;
      0) exit 0 ;;
      *) echo "Invalid option" ;;
    esac
  done
}

check_root() {
  [ "$EUID" -ne 0 ] && { echo "Please run as root"; exit 1; }
}

check_root
main_menu
