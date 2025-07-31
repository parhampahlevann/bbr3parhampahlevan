#!/bin/bash

set -e

CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo bash bbrvipparham.sh)"
    exit 1
  fi
}

check_kernel_version() {
  local version
  version=$(uname -r | awk -F. '{print $1"."$2}')
  local required="6.1"

  if printf '%s\n' "$required" "$version" | sort -V -C; then
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
  echo "✅ BBRv3 applied successfully."
  sysctl net.ipv4.tcp_congestion_control
}

upgrade_kernel() {
  echo "⬆️  Upgrading kernel to 6.5..."

  cd /tmp
  arch=$(uname -m)
  kernel_version="6.5.10"

  if [[ "$arch" == "x86_64" ]]; then
    base_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel_version}/amd64"
    files=(
      "linux-headers-${kernel_version}-060510-generic_${kernel_version}-060510.202310281035_amd64.deb"
      "linux-headers-${kernel_version}-060510_${kernel_version}-060510.202310281035_all.deb"
      "linux-image-unsigned-${kernel_version}-060510-generic_${kernel_version}-060510.202310281035_amd64.deb"
      "linux-modules-${kernel_version}-060510-generic_${kernel_version}-060510.202310281035_amd64.deb"
    )
  elif [[ "$arch" == "aarch64" ]]; then
    base_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel_version}/arm64"
    files=(
      "linux-headers-${kernel_version}-060510-generic_${kernel_version}-060510.202310281035_arm64.deb"
      "linux-headers-${kernel_version}-060510_${kernel_version}-060510.202310281035_all.deb"
      "linux-image-unsigned-${kernel_version}-060510-generic_${kernel_version}-060510.202310281035_arm64.deb"
      "linux-modules-${kernel_version}-060510-generic_${kernel_version}-060510.202310281035_arm64.deb"
    )
  else
    echo "⚠️ Unsupported architecture: $arch"
    exit 1
  fi

  for file in "${files[@]}"; do
    wget -c --no-check-certificate "$base_url/$file"
  done

  dpkg -i *.deb
  echo "✅ Kernel ${kernel_version} installed. Please reboot now to apply."
}

uninstall_bbr3() {
  echo "🧹 Removing BBRv3 settings..."
  rm -f "$CONFIG_FILE"
  sysctl -w net.core.default_qdisc=cake >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  sysctl --system
  echo "✔️  Settings reverted to default."
}

reboot_now() {
  echo "🔄 Rebooting system..."
  reboot
}

main_menu() {
  while true; do
    echo ""
    echo "========= BBRv3 Optimizer by Parham Pahlevan ========="
    echo "1) Install BBRv3 (auto kernel upgrade if needed)"
    echo "2) Uninstall and reset sysctl settings"
    echo "3) Reboot system"
    echo "0) Exit"
    echo "======================================================"
    read -rp "Choose an option [0-3]: " opt

    case "$opt" in
      1)
        if check_kernel_version; then
          install_bbr3
        else
          echo "⚠️ Your kernel is too old. Updating to 6.5..."
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
        echo "Invalid input. Try again."
        ;;
    esac
  done
}

check_root
main_menu
