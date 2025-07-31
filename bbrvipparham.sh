#!/bin/bash

set -e

CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (use: sudo bash bbrvipparham.sh)"
  exit 1
fi

# Check required tools
for cmd in curl uname sysctl; do
  if ! command -v $cmd &>/dev/null; then
    echo "Missing required command: $cmd. Please install it first."
    exit 1
  fi
done

# Detect architecture and Ubuntu version
arch=$(uname -m)
ubuntu_version=$(lsb_release -rs 2>/dev/null || grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release)
kernel_version=$(uname -r | cut -d '-' -f1)
major=$(echo "$kernel_version" | cut -d '.' -f1)
minor=$(echo "$kernel_version" | cut -d '.' -f2)

echo "Detected Architecture: $arch"
echo "Ubuntu Version: $ubuntu_version"
echo "Kernel Version: $kernel_version"

# Check kernel version compatibility
if [ "$major" -lt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -lt 1 ]; }; then
  echo "Kernel does not support BBRv3. You must upgrade to 6.1 or newer."
  exit 1
fi

# Function to install BBR3
install_bbr3() {
  echo "Installing BBRv3 and optimizing TCP performance..."

  cat > "$CONFIG_FILE" <<EOF
# BBRv3 Optimized Settings by Parham Pahlevan
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

  sysctl --system
  echo ""
  echo "BBRv3 has been installed and optimized successfully."
  sysctl net.ipv4.tcp_congestion_control
}

# Function to uninstall
uninstall_bbr3() {
  echo "Removing BBRv3 settings..."
  rm -f "$CONFIG_FILE"
  sysctl -w net.core.default_qdisc=cake >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl --system
  echo "System settings reverted to default."
}

# Function to reboot
reboot_system() {
  echo "Rebooting system..."
  reboot
}

# Main menu
while true; do
  echo ""
  echo "============ BBRv3 Optimizer by Parham Pahlevan ============"
  echo "1) Install BBR3 (TCP Optimizer)"
  echo "2) Uninstall and Reset Settings"
  echo "3) Reboot System"
  echo "0) Exit"
  echo "============================================================="
  read -p "Choose an option [0-3]: " choice

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
      echo "Exiting script."
      exit 0
      ;;
    *)
      echo "Invalid choice. Please enter 0 to 3."
      ;;
  esac
done
