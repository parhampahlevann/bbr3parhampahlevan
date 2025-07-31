#!/bin/bash

set -e

CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
KERNEL_VERSION="6.6.8"
MIRRORS=(
  "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${KERNEL_VERSION}"
  "http://mirrors.edge.kernel.org/pub/linux/kernel/v6.x"
  "https://ftp.us.debian.org/debian/pool/main/l/linux/"
)

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo bash $0)"
    exit 1
  fi
}

check_internet() {
  local test_urls=("google.com" "kernel.ubuntu.com" "1.1.1.1")
  for url in "${test_urls[@]}"; do
    if ping -c 1 -W 3 "$url" &> /dev/null; then
      return 0
    fi
  done
  echo "❌ No internet connection detected"
  exit 1
}

check_kernel_version() {
  local current_version=$(uname -r | awk -F. '{ printf("%d.%d", $1,$2) }')
  local required_version="4.9"
  (( $(echo "$current_version >= $required_version" | bc -l) )) && return 0 || return 1
}

optimize_network() {
  cat > "$CONFIG_FILE" <<'EOF'
# Ultra-Optimized BBRv3 Settings
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# Buffer Optimizations
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.tcp_rmem = 8192 87380 134217728
net.ipv4.tcp_wmem = 8192 65536 134217728

# QUIC/HTTP3 Optimizations
net.core.netdev_max_backlog = 200000
net.core.somaxconn = 65535
net.core.optmem_max = 4194304

# Latency Reduction
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 8

# Security Hardening
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rfc1337 = 1
EOF

  # Additional optimizations
  echo "* soft nofile 1048576" >> /etc/security/limits.conf
  echo "* hard nofile 1048576" >> /etc/security/limits.conf
  
  sysctl --system
  modprobe tcp_bbr
  echo "✅ Network optimization completed!"
}

download_kernel_packages() {
  local arch=$1
  cd /tmp
  rm -f *.deb

  if [[ "$arch" == "x86_64" ]]; then
    packages=(
      "amd64/linux-headers-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_amd64.deb"
      "amd64/linux-headers-${KERNEL_VERSION}_${KERNEL_VERSION}_all.deb"
      "amd64/linux-image-unsigned-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_amd64.deb"
      "amd64/linux-modules-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_amd64.deb"
    )
  elif [[ "$arch" == "aarch64" ]]; then
    packages=(
      "arm64/linux-headers-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_arm64.deb"
      "arm64/linux-headers-${KERNEL_VERSION}_${KERNEL_VERSION}_all.deb"
      "arm64/linux-image-unsigned-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_arm64.deb"
      "arm64/linux-modules-${KERNEL_VERSION}-generic_${KERNEL_VERSION}_arm64.deb"
    )
  else
    echo "❌ Unsupported architecture: $arch"
    exit 1
  fi

  for pkg in "${packages[@]}"; do
    for mirror in "${MIRRORS[@]}"; do
      if wget -c --no-check-certificate "${mirror}/${pkg}"; then
        break
      fi
    done || { echo "❌ Failed to download ${pkg}"; exit 1; }
  done
}

upgrade_kernel() {
  check_internet
  arch=$(uname -m)
  download_kernel_packages "$arch"
  
  if dpkg -i *.deb || (apt-get install -f -y && dpkg -i *.deb); then
    echo "✅ Kernel upgraded successfully"
  else
    echo "❌ Kernel installation failed"
    exit 1
  fi
}

uninstall_bbr3() {
  rm -f "$CONFIG_FILE"
  sysctl -w net.core.default_qdisc=fq_codel
  sysctl -w net.ipv4.tcp_congestion_control=cubic
  sysctl --system
  echo "✔️ BBRv3 settings removed"
}

main_menu() {
  while true; do
    echo ""
    echo "========= BBRv3 Ultimate Optimizer ========="
    echo "1) Install BBRv3 (Auto Kernel Upgrade)"
    echo "2) Remove BBRv3"
    echo "3) Check Current Settings"
    echo "0) Exit"
    echo "============================================"
    read -rp "Select option [0-3]: " opt

    case "$opt" in
      1)
        if check_kernel_version; then
          optimize_network
        else
          upgrade_kernel
          optimize_network
        fi
        ;;
      2) uninstall_bbr3 ;;
      3) sysctl net.ipv4.tcp_congestion_control ;;
      0) exit 0 ;;
      *) echo "Invalid option" ;;
    esac
  done
}

check_root
main_menu
