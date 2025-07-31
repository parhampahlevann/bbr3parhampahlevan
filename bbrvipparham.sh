#!/bin/bash

set -e

CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
KERNEL_VERSION="6.6.8"  # Latest stable kernel version
UBUNTU_URL="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${KERNEL_VERSION}"
KERNEL_ORG_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo bash bbrvipparham.sh)"
    exit 1
  fi
}

check_kernel_version() {
  local current_version=$(uname -r | awk -F. '{ printf("%d.%d", $1,$2) }')
  local required_version="6.1"

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

download_kernel_packages() {
  local arch=$1
  local files=()

  if [[ "$arch" == "x86_64" ]]; then
    files=(
      "linux-headers-${KERNEL_VERSION}_${KERNEL_VERSION}.amd64.deb"
      "linux-headers-${KERNEL_VERSION}-generic_${KERNEL_VERSION}.amd64.deb"
      "linux-image-unsigned-${KERNEL_VERSION}-generic_${KERNEL_VERSION}.amd64.deb"
      "linux-modules-${KERNEL_VERSION}-generic_${KERNEL_VERSION}.amd64.deb"
    )
  elif [[ "$arch" == "aarch64" ]]; then
    files=(
      "linux-headers-${KERNEL_VERSION}_${KERNEL_VERSION}.arm64.deb"
      "linux-headers-${KERNEL_VERSION}-generic_${KERNEL_VERSION}.arm64.deb"
      "linux-image-unsigned-${KERNEL_VERSION}-generic_${KERNEL_VERSION}.arm64.deb"
      "linux-modules-${KERNEL_VERSION}-generic_${KERNEL_VERSION}.arm64.deb"
    )
  else
    echo "⚠️ Unsupported architecture: $arch"
    exit 1
  fi

  # Try multiple download sources
  for file in "${files[@]}"; do
    echo "Downloading: $file"
    if ! wget -c --no-check-certificate "${UBUNTU_URL}/${arch}/${file}"; then
      echo "Ubuntu server failed, trying kernel.org mirror..."
      if ! wget -c "${KERNEL_ORG_URL}/${file}"; then
        echo "❌ Failed to download kernel packages"
        exit 1
      fi
    fi
  done
}

upgrade_kernel() {
  echo "⬆️  Upgrading kernel to version ${KERNEL_VERSION}..."

  cd /tmp
  arch=$(uname -m)
  
  download_kernel_packages "$arch"

  # Install kernel packages
  dpkg -i *.deb || {
    echo "⚠️ Error installing kernel packages, attempting dependency resolution..."
    apt-get install -f -y
    dpkg -i *.deb
  }

  echo "✅ Kernel ${KERNEL_VERSION} successfully installed. Please reboot your system."
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
    echo "========= BBRv3 Optimizer by Parham Pahlevan ========="
    echo "1) Install BBRv3 (auto kernel upgrade if needed)"
    echo "2) Uninstall and reset configuration"
    echo "3) Reboot system"
    echo "0) Exit"
    echo "======================================================"
    read -rp "Please select an option [0-3]: " opt

    case "$opt" in
      1)
        if check_kernel_version; then
          install_bbr3
        else
          echo "⚠️ Your kernel version is outdated. Upgrading to ${KERNEL_VERSION}..."
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
