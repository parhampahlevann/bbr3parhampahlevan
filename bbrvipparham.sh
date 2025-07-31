#!/bin/bash

set -e

CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
KERNEL_VERSION="6.6.8"  # Latest stable kernel version

# Multiple download mirrors
MIRRORS=(
  "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${KERNEL_VERSION}"
  "https://mirrors.edge.kernel.org/pub/linux/kernel/v6.x"
  "http://ftp.us.debian.org/debian/pool/main/l/linux/"
)

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo bash $0)"
    exit 1
  fi
}

check_kernel_version() {
  local current_version=$(uname -r | awk -F. '{ printf("%d.%d", $1,$2) }')
  local required_version="4.9"  # Minimum for BBR

  if (( $(echo "$current_version >= $required_version" | bc -l) )); then
    return 0
  else
    return 1
  fi
}

install_bbr3() {
  echo "✅ Installing BBRv3 and applying optimized sysctl settings..."

  cat > "$CONFIG_FILE" <<EOF
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
  echo "✅ BBRv3 successfully configured."
  sysctl net.ipv4.tcp_congestion_control
}

download_with_fallback() {
  local url=$1
  local file=$2
  local mirror
  
  for mirror in "${MIRRORS[@]}"; do
    if wget -c --no-check-certificate "${mirror}/${url}" -O "$file"; then
      return 0
    fi
  done
  
  return 1
}

download_kernel_packages() {
  local arch=$1
  echo "🔍 Detected architecture: $arch"

  cd /tmp
  rm -f *.deb  # Clean previous downloads

  if [[ "$arch" == "x86_64" ]]; then
    declare -A packages=(
      ["headers-generic"]="amd64/linux-headers-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_amd64.deb"
      ["headers-all"]="amd64/linux-headers-${KERNEL_VERSION}_${KERNEL_VERSION}_all.deb"
      ["image-unsigned"]="amd64/linux-image-unsigned-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_amd64.deb"
      ["modules"]="amd64/linux-modules-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_amd64.deb"
    )
  elif [[ "$arch" == "aarch64" ]]; then
    declare -A packages=(
      ["headers-generic"]="arm64/linux-headers-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_arm64.deb"
      ["headers-all"]="arm64/linux-headers-${KERNEL_VERSION}_${KERNEL_VERSION}_all.deb"
      ["image-unsigned"]="arm64/linux-image-unsigned-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_arm64.deb"
      ["modules"]="arm64/linux-modules-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_arm64.deb"
    )
  else
    echo "❌ Unsupported architecture: $arch"
    exit 1
  fi

  for pkg in "${!packages[@]}"; do
    echo "📦 Downloading ${pkg} package..."
    if ! download_with_fallback "${packages[$pkg]}" "${pkg}.deb"; then
      echo "❌ Failed to download ${pkg} package from all mirrors"
      exit 1
    fi
  done
}

upgrade_kernel() {
  echo "⬆️  Upgrading kernel to version ${KERNEL_VERSION}..."
  
  # Check internet connection
  if ! ping -c 1 kernel.ubuntu.com &> /dev/null && ! ping -c 1 google.com &> /dev/null; then
    echo "❌ No internet connection detected"
    exit 1
  fi

  arch=$(uname -m)
  download_kernel_packages "$arch"

  echo "🔧 Installing kernel packages..."
  if ! dpkg -i *.deb; then
    echo "⚠️ Attempting to fix dependencies..."
    apt-get update
    apt-get install -f -y
    if ! dpkg -i *.deb; then
      echo "❌ Failed to install kernel packages"
      exit 1
    fi
  fi

  echo "✅ Kernel ${KERNEL_VERSION} successfully installed. Please reboot."
}

uninstall_bbr3() {
  echo "🧹 Removing BBRv3 configuration..."
  rm -f "$CONFIG_FILE"
  sysctl -w net.core.default_qdisc=cake >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl --system
  echo "✔️ Configuration restored to defaults."
}

reboot_now() {
  read -p "Do you want to reboot now? [y/N] " choice
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

main_menu() {
  while true; do
    echo ""
    echo "========= Ultimate BBRv3 Optimizer ========="
    echo "1) Install BBRv3 (auto kernel upgrade)"
    echo "2) Uninstall and reset configuration"
    echo "3) Reboot system"
    echo "0) Exit"
    echo "==========================================="
    read -rp "Please select an option [0-3]: " opt

    case "$opt" in
      1)
        if check_kernel_version; then
          install_bbr3
        else
          upgrade_kernel
        fi
        ;;
      2)
        uninstall_bbr3
        ;;
      3)
        reboot_now
        ;;
      0)
        echo "Exiting..."
        exit 0
        ;;
      *)
        echo "Invalid selection. Please try again."
        ;;
    esac
  done
}

check_root
main_menu
