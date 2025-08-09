#!/usr/bin/env bash
set -euo pipefail
LANG=C.UTF-8

# -------- Functions --------
log() { echo -e "\e[32m[$(date '+%F %T')]\e[0m $*"; }
error() { echo -e "\e[31mError: $*\e[0m" >&2; }
pause() { read -rp "Press Enter to continue..."; }
ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Please run as root."
    exit 1
  fi
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
check_kernel_version() {
  local major minor
  major=$(uname -r | cut -d '.' -f1)
  minor=$(uname -r | cut -d '.' -f2 | cut -d '-' -f1)
  echo "$major.$minor"
}
install_kernel_hwe() {
  log "Installing latest HWE kernel for better BBR2 support..."
  apt-get update -y
  apt-get install -y --no-install-recommends linux-generic-hwe-$(lsb_release -rs) linux-headers-generic-hwe-$(lsb_release -rs)
  log "Kernel installation done. Please reboot after installation."
}
apply_sysctl() {
  local sysctl_file="/etc/sysctl.d/99-bbr2-tuned.conf"
  backup_file "$sysctl_file"
  cat >"$sysctl_file" <<EOF
# BBR2 Optimized Settings
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr2

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 10000

net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

net.ipv4.tcp_bbr2_bw_probe_cwnd_gain = 2
net.ipv4.tcp_bbr2_extra_acked_gain = 1
net.ipv4.tcp_bbr2_cwnd_min = 4

net.ipv4.tcp_ecn = 0
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_orphan_retries = 2
EOF
  sysctl --system
  log "Sysctl parameters applied."
}
enable_bbr2_module() {
  if ! modprobe tcp_bbr2 >/dev/null 2>&1; then
    error "tcp_bbr2 module not found in kernel. BBR2 not supported. Please update your kernel."
    return 1
  fi
  log "tcp_bbr2 kernel module loaded."
}
enable_bbr2_module_load_on_boot() {
  echo "tcp_bbr2" > /etc/modules-load.d/bbr2.conf
  log "tcp_bbr2 module will be loaded on boot."
}
check_bbr2_enabled() {
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control)
  [[ "$cc" == "bbr2" ]]
}
show_status() {
  echo "----- Current Status -----"
  echo "Kernel version: $(uname -r)"
  echo "TCP Congestion Control: $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "Default qdisc: $(sysctl -n net.core.default_qdisc)"
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
  rm -f /etc/modules-load.d/bbr2.conf
  sysctl -w net.ipv4.tcp_congestion_control=cubic || true
  sysctl -w net.core.default_qdisc=fq || true
  for iface in $(get_interfaces); do
    ip link set dev "$iface" mtu 1500 || true
  done
  log "BBR2 and related settings removed. Reboot is recommended."
}
menu() {
  clear
  echo "======================================"
  echo "   Ultra Fast & Stable BBR2 Setup     "
  echo "======================================"
  echo "1) Install/Enable BBR2 (with kernel check)"
  echo "2) Remove BBR2 & Restore Defaults"
  echo "3) Change DNS (current: $(get_current_dns))"
  echo "4) Change MTU (current: $(get_current_mtu))"
  echo "5) Show Status"
  echo "6) Reboot Server"
  echo "0) Exit"
  echo "======================================"
  read -rp "Select option: " choice
  case $choice in
    1)
      install_bbr2_flow
      ;;
    2)
      remove_bbr2
      pause
      ;;
    3)
      change_dns
      ;;
    4)
      change_mtu
      ;;
    5)
      show_status
      pause
      ;;
    6)
      log "Rebooting now..."
      reboot
      ;;
    0)
      exit 0
      ;;
    *)
      error "Invalid option"
      pause
      ;;
  esac
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
  local kernel_major kernel_minor
  kernel_major=$(uname -r | cut -d '.' -f1)
  kernel_minor=$(uname -r | cut -d '.' -f2 | cut -d '-' -f1)
  if (( kernel_major < 5 || (kernel_major == 5 && kernel_minor < 10) )); then
    log "Kernel version too old ($(uname -r)). Installing HWE kernel..."
    install_kernel_hwe
    log "Please reboot your server and rerun the script to continue BBR2 setup."
    exit 0
  fi
  enable_bbr2_module || exit 1
  enable_bbr2_module_load_on_boot
  apply_sysctl
  set_dns "1.1.1.1"
  set_mtu 1420
  if check_bbr2_enabled; then
    log "BBR2 enabled successfully."
  else
    error "Failed to enable BBR2 congestion control."
    exit 1
  fi
  pause
}

# -------- Main --------
while true; do
  menu
done
