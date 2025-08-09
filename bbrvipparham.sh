#!/usr/bin/env bash
set -euo pipefail
LANG=C.UTF-8

log() { echo -e "\e[32m[$(date '+%F %T')]\e[0m $*"; }
error() { echo -e "\e[31mError: $*\e[0m" >&2; }
pause() { read -rp "Press Enter to continue..."; }
ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Please run as root."
    exit 1
  fi
}
check_internet() {
  if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    error "No internet connection. Please check your network and try again."
    exit 1
  fi
  log "Internet connection verified."
}
check_disk_space() {
  local required_space=2048  # 2GB in MB
  local available_space
  available_space=$(df -m / | tail -1 | awk '{print $4}')
  if (( available_space < required_space )); then
    error "Insufficient disk space. At least 2GB is required. Available: ${available_space}MB"
    exit 1
  fi
  log "Sufficient disk space available: ${available_space}MB"
}
backup_file() {
  local file=$1
  if [[ -f "$file" && ! -f "$file.bak-bbr2" ]]; then
    cp "$file" "$file.bak-bbr2"
    log "Backup created for $file"
  fi
}
restore_backup() {
  local file=$1
  if [[ -f "$file.bak-bbr2" ]]; then
    mv -f "$file.bak-bbr2" "$file"
    log "Backup restored for $file"
  fi
}
get_interfaces() {
  ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker.*|veth.*|br-|tun|tap|wg|virbr|lxc|vnet)'
}
set_mtu() {
  local mtu_value=$1
  for iface in $(get_interfaces); do
    ip link set dev "$iface" mtu "$mtu_value" || log "Failed to set MTU on $iface"
  done
  log "MTU set to $mtu_value on physical interfaces."
}
set_dns() {
  local dns_value=$1
  if systemctl is-active --quiet systemd-resolved; then
    backup_file /etc/systemd/resolved.conf
    echo -e "[Resolve]\nDNS=$dns_value\n" > /etc/systemd/resolved.conf
    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  else
    backup_file /etc/resolv.conf
    echo "nameserver $dns_value" > /etc/resolv.conf
  fi
  log "DNS set to $dns_value"
}
detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    error "No supported package manager found (apt/yum/dnf)."
    exit 1
  fi
}
configure_repos() {
  local pkg_manager
  pkg_manager=$(detect_package_manager)
  case $pkg_manager in
    apt)
      if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
          log "Configuring Ubuntu repositories..."
          cat >/etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $VERSION_CODENAME-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $VERSION_CODENAME-security main restricted universe multiverse
EOF
        elif [[ "$ID" == "debian" ]]; then
          log "Configuring Debian repositories..."
          cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian $VERSION_CODENAME main contrib non-free
deb http://deb.debian.org/debian $VERSION_CODENAME-updates main contrib non-free
deb http://security.debian.org/debian-security $VERSION_CODENAME-security main contrib non-free
EOF
        else
          error "Unsupported distribution: $ID. Please configure repositories manually."
          exit 1
        fi
      fi
      if ! apt-get update -y; then
        error "Failed to update package repositories. Check your internet connection or /etc/apt/sources.list."
        exit 1
      fi
      ;;
    dnf|yum)
      log "Checking $pkg_manager repositories..."
      if ! $pkg_manager makecache; then
        error "Failed to update package repositories. Check your repo configuration or internet connection."
        exit 1
      fi
      ;;
  esac
}
check_kernel_version() {
  local kv
  kv=$(uname -r | cut -d'-' -f1)
  echo "$kv"
}
install_kernel_hwe() {
  log "Checking prerequisites for kernel installation..."
  check_internet
  check_disk_space
  configure_repos
  local pkg_manager
  pkg_manager=$(detect_package_manager)
  log "Installing new kernel using $pkg_manager..."
  case $pkg_manager in
    apt)
      local release
      release=$(lsb_release -rs 2>/dev/null || grep '^VERSION_ID=' /etc/os-release | cut -d'"' -f2)
      local distro_id
      distro_id=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
      if [[ "$distro_id" == "ubuntu" && -n "$release" ]]; then
        log "Attempting to install Ubuntu HWE kernel for $release..."
        if ! apt-get install -y --install-recommends linux-generic-hwe-"$release" linux-headers-generic-hwe-"$release"; then
          log "HWE kernel installation failed. Trying generic kernel..."
          if ! apt-get install -y linux-image-amd64 linux-headers-amd64; then
            error "Failed to install kernel. Try manually with: sudo apt-get install linux-image-amd64"
            exit 1
          fi
        fi
      else
        log "Installing generic kernel for $distro_id..."
        if ! apt-get install -y linux-image-amd64 linux-headers-amd64; then
          error "Failed to install kernel. Try manually with: sudo apt-get install linux-image-amd64"
          exit 1
        fi
      fi
      ;;
    dnf)
      if ! dnf install -y kernel kernel-devel kernel-headers; then
        error "Failed to install kernel. Try manually with: sudo dnf install kernel kernel-devel kernel-headers"
        exit 1
      fi
      ;;
    yum)
      if ! yum install -y kernel kernel-devel kernel-headers; then
        error "Failed to install kernel. Try manually with: sudo yum install kernel kernel-devel kernel-headers"
        exit 1
      fi
      ;;
  esac
  log "Kernel installation completed. Please reboot your server with 'sudo reboot' and rerun the script."
  log "After reboot, verify kernel version with 'uname -r'. It should be 5.10 or higher."
  pause
  exit 0
}
enable_bbr2_module() {
  if ! ls /lib/modules/$(uname -r)/kernel/net/ipv4/tcp_bbr2.ko* >/dev/null 2>&1; then
    error "tcp_bbr2 module not found in kernel modules directory."
    log "Your kernel ($(uname -r)) may not support BBR2. Ensure it is 5.10 or higher and CONFIG_TCP_CONG_BBR2=m is enabled."
    log "To compile a custom kernel:"
    log "1. Install kernel sources: sudo apt-get install linux-source (or equivalent for your distro)"
    log "2. Run 'make menuconfig', enable CONFIG_TCP_CONG_BBR2=m"
    log "3. Rebuild and install the kernel."
    return 1
  fi
  if ! modprobe tcp_bbr2 >/dev/null 2>&1; then
    error "Failed to load tcp_bbr2 module. Check kernel configuration."
    return 1
  fi
  if ! lsmod | grep -q tcp_bbr2; then
    error "tcp_bbr2 module is not loaded."
    return 1
  fi
  log "tcp_bbr2 kernel module loaded successfully."
}
check_qdisc_fq() {
  if ! tc qdisc show | grep -q fq; then
    log "Fair Queue (fq) qdisc not available. Falling back to default qdisc."
    return 1
  fi
  return 0
}
apply_sysctl() {
  local sysctl_file="/etc/sysctl.d/99-bbr2-tuned.conf"
  backup_file "$sysctl_file"
  cat >"$sysctl_file" <<EOF
# BBR2 optimized sysctl settings
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr2
net.ipv6.tcp_congestion_control = bbr2

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 2500

net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv6.tcp_mtu_probing = 1

net.ipv4.tcp_bbr2_bw_probe_cwnd_gain = 2
net.ipv4.tcp_bbr2_extra_acked_gain = 1
net.ipv4.tcp_bbr2_cwnd_min = 4

net.ipv4.tcp_ecn = 0
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 2
EOF
  if ! check_qdisc_fq; then
    sed -i '/net.core.default_qdisc/d' "$sysctl_file"
  fi
  if ! sysctl --system; then
    error "Failed to apply sysctl settings. Check /etc/sysctl.d/99-bbr2-tuned.conf for errors."
    return 1
  fi
  log "Sysctl parameters applied."
}
tune_bbr2_params() {
  read -rp "Enter tcp_bbr2_bw_probe_cwnd_gain (default 2): " cwnd_gain
  cwnd_gain=${cwnd_gain:-2}
  read -rp "Enter tcp_bbr2_extra_acked_gain (default 1): " acked_gain
  acked_gain=${acked_gain:-1}
  read -rp "Enter tcp_bbr2_cwnd_min (default 4): " cwnd_min
  cwnd_min=${cwnd_min:-4}
  backup_file /etc/sysctl.d/99-bbr2-tuned.conf
  sed -i "/tcp_bbr2_bw_probe_cwnd_gain/c\net.ipv4.tcp_bbr2_bw_probe_cwnd_gain=$cwnd_gain" /etc/sysctl.d/99-bbr2-tuned.conf
  sed -i "/tcp_bbr2_extra_acked_gain/c\net.ipv4.tcp_bbr2_extra_acked_gain=$acked_gain" /etc/sysctl.d/99-bbr2-tuned.conf
  sed -i "/tcp_bbr2_cwnd_min/c\net.ipv4.tcp_bbr2_cwnd_min=$cwnd_min" /etc/sysctl.d/99-bbr2-tuned.conf
  if ! sysctl --system; then
    error "Failed to apply updated BBR2 parameters."
    pause
    return
  fi
  log "BBR2 parameters updated."
  pause
}
check_bbr2_enabled() {
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control)
  if [[ "$cc" != "bbr2" ]]; then
    return 1
  fi
  if ! lsmod | grep -q tcp_bbr2; then
    return 1
  fi
  return 0
}
show_status() {
  echo "----- Current Status -----"
  echo "Kernel version: $(uname -r)"
  echo "TCP Congestion Control (IPv4): $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "TCP Congestion Control (IPv6): $(sysctl -n net.ipv6.tcp_congestion_control)"
  echo "Default qdisc: $(sysctl -n net.core.default_qdisc)"
  echo "Loaded modules: $(lsmod | grep bbr || echo 'No BBR modules loaded')"
  echo "MTU values:"
  for iface in $(get_interfaces); do
    mtu=$(ip link show "$iface" | awk '/mtu/ {print $5}')
    echo "  $iface: $mtu"
  done
  echo "DNS settings:"
  if systemctl is-active --quiet systemd-resolved; then
    grep '^DNS=' /etc/systemd/resolved.conf || echo "Default systemd-resolved settings"
  else
    head -2 /etc/resolv.conf
  fi
  echo "--------------------------"
}
remove_bbr2() {
  log "Removing BBR2 settings and restoring backups..."
  restore_backup /etc/sysctl.d/99-bbr2-tuned.conf
  restore_backup /etc/systemd/resolved.conf
  restore_backup /etc/resolv.conf
  sysctl -w net.ipv4.tcp_congestion_control=cubic || true
  sysctl -w net.ipv6.tcp_congestion_control=cubic || true
  sysctl -w net.core.default_qdisc=fq || true
  for iface in $(get_interfaces); do
    ip link set dev "$iface" mtu 1500 || true
  done
  log "BBR2 and related settings removed. Reboot is recommended."
}
get_current_dns() {
  if systemctl is-active --quiet systemd-resolved; then
    grep '^DNS=' /etc/systemd/resolved.conf | cut -d= -f2 || echo "1.1.1.1"
  else
    grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}' || echo "1.1.1.1"
  fi
}
get_current_mtu() {
  for iface in $(get_interfaces); do
    ip link show "$iface" | awk '/mtu/ {print $5; exit}'
    return
  done
  echo "1500"
}
change_dns() {
  read -rp "Enter new DNS IP (e.g. 1.1.1.1): " new_dns
  if [[ ! "$new_dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid IP format."
    pause
    return
  fi
  set_dns "$new_dns"
  pause
}
change_mtu() {
  read -rp "Enter new MTU (1280-9000, e.g. 1420): " new_mtu
  if ! [[ "$new_mtu" =~ ^[0-9]+$ ]] || ((new_mtu < 1280 || new_mtu > 9000)); then
    error "MTU must be a number between 1280 and 9000."
    pause
    return
  fi
  set_mtu "$new_mtu"
  pause
}
install_bbr2_flow() {
  ensure_root
  log "Starting BBR2 installation and setup..."
  check_internet
  check_disk_space
  local kernel_ver
  kernel_ver=$(uname -r | cut -d'-' -f1)
  kernel_ver_num=$(echo "$kernel_ver" | awk -F. '{print $1*10000 + $2*100 + $3}')
  local required_ver=51000  # 5.10.0 minimum for BBR2
  
  if (( kernel_ver_num < required_ver )); then
    log "Kernel version $kernel_ver is too old for BBR2. Installing a newer kernel..."
    install_kernel_hwe
  fi

  if ! enable_bbr2_module; then
    error "Failed to enable BBR2 module. Please ensure kernel supports tcp_bbr2."
    exit 1
  fi
  if ! apply_sysctl; then
    error "Failed to apply sysctl settings. Check system configuration."
    exit 1
  fi
  set_dns "1.1.1.1"
  set_mtu 1420
  if check_bbr2_enabled; then
    log "BBR2 enabled successfully!"
  else
    error "Failed to enable BBR2. Check kernel module and sysctl settings."
    exit 1
  fi
  pause
}
menu() {
  clear
  echo "======================================"
  echo "   Ultra Fast & Stable BBR2 Setup     "
  echo "======================================"
  echo "System Info:"
  echo "  Kernel: $(uname -r)"
  echo "  Distro: $(lsb_release -ds 2>/dev/null || grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2 || echo 'Unknown')"
  echo "  TCP CC: $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "======================================"
  echo "1) Install/Enable BBR2 (with kernel check)"
  echo "2) Remove BBR2 & Restore Defaults"
  echo "3) Change DNS (current: $(get_current_dns))"
  echo "4) Change MTU (current: $(get_current_mtu))"
  echo "5) Show Status"
  echo "6) Tune BBR2 Parameters"
  echo "7) Reboot Server"
  echo "0) Exit"
  echo "======================================"
  read -rp "Select option: " choice
  case $choice in
    1) install_bbr2_flow ;;
    2) remove_bbr2; pause ;;
    3) change_dns ;;
    4) change_mtu ;;
    5) show_status; pause ;;
    6) tune_bbr2_params ;;
    7) log "Rebooting now..."; reboot ;;
    0) exit 0 ;;
    *) error "Invalid option"; pause ;;
  esac
}

# Main loop
while true; do
  menu
done
