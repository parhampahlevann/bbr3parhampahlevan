#!/bin/bash

set -e

CONFIG_FILE="/etc/sysctl.d/99-bbr.conf"

# Ensure root access
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script as root (use sudo)."
  exit 1
fi

function install_bbr3() {
  echo "🚀 Installing BBR3 by Parham Pahlevan..."

  # Kernel version check
  kernel_version=$(uname -r | cut -d '-' -f1)
  major=$(echo "$kernel_version" | cut -d '.' -f1)
  minor=$(echo "$kernel_version" | cut -d '.' -f2)

  echo "🔍 Current kernel version: $kernel_version"

  if [ "$major" -lt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -lt 1 ]; }; then
    echo "⚠️ Your kernel does not support BBRv3. Please upgrade to kernel 6.1 or newer."
    exit 1
  fi

  # Create sysctl config file
  echo "🛠️ Applying system tuning for BBR3..."

  cat > "$CONFIG_FILE" <<EOF
# Enable BBRv3 and fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Increase TCP buffer sizes
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Enable TCP Fast Open (reduces latency)
net.ipv4.tcp_fastopen = 3

# Improve TCP reliability
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1

# Low latency
net.ipv4.tcp_low_latency = 1

# TCP connection timers
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

  sysctl --system

  echo ""
  echo "✅ BBR3 installation complete!"
  sysctl net.ipv4.tcp_congestion_control
}

function uninstall_bbr3() {
  echo "🧹 Removing BBR configuration and restoring defaults..."

  if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo "🗑️ Removed: $CONFIG_FILE"
  else
    echo "ℹ️ No configuration file found to remove."
  fi

  # Reset default parameters
  sysctl -w net.core.default_qdisc=cake >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true

  sysctl --system

  echo "✅ System settings have been reset to defaults."
}

function reboot_system() {
  echo "🔁 Rebooting system..."
  reboot
}

# Menu
while true; do
  echo ""
  echo "============== BBR3 Network Optimizer =============="
  echo "1) Install BBR3 By Parham Pahlevan"
  echo "2) Uninstall (Reset to Default Settings)"
  echo "3) Reboot"
  echo "0) Exit"
  echo "===================================================="
  read -p "Please select an option [0-3]: " choice

  case $choice in
    1)
      install_bbr3
      ;;
    2)
      uninstall_bbr3
      ;;
    3)
      reboot_system
      ;;
    0)
      echo "👋 Exiting script. Goodbye!"
      exit 0
      ;;
    *)
      echo "❌ Invalid option! Please enter a number between 0 and 3."
      ;;
  esac
done
