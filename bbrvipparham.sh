#!/usr/bin/env bash
# bbr2-super-english.sh
# English version — BBR2 (preferred) with fallback to BBR
# Provides menu: install, uninstall, manual DNS/MTU, show status, reboot.
# Persists settings across reboots via systemd service and sysctl.d.
# Usage: sudo ./bbr2-super-english.sh
set -euo pipefail
LANG=C.UTF-8

BACKUP_DIR="/etc/bbr_super_backup_$(date +%s)"
SYSCTL_CONF="/etc/sysctl.d/99-bbr2-tuning.conf"
SERVICE_FILE="/etc/systemd/system/bbr2-apply.service"
APPLY_SCRIPT="/usr/local/sbin/bbr2-apply.sh"
DNS_VALUE_FILE="/etc/bbr_dns_value"
MTU_VALUE_FILE="/etc/bbr_mtu_value"

DEFAULT_DNS="1.1.1.1"
DEFAULT_MTU="1420"

######## helpers ########
ensure_root(){
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)."
    exit 1
  fi
}

log(){
  echo -e "[$(date '+%F %T')] $*"
}

backup_file(){
  f="$1"
  mkdir -p "$BACKUP_DIR"
  if [ -e "$f" ]; then
    cp -a "$f" "$BACKUP_DIR/"
  fi
}

do_backup(){
  log "Backing up important files to $BACKUP_DIR ..."
  mkdir -p "$BACKUP_DIR"
  backup_file /etc/resolv.conf
  backup_file /etc/systemd/resolved.conf
  backup_file /etc/netplan  || true
  backup_file /etc/sysctl.conf || true
  backup_file "$SYSCTL_CONF" || true
  backup_file "$SERVICE_FILE" || true
  log "Backup complete."
}

install_prereqs(){
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 ethtool curl coreutils ca-certificates
  else
    log "No apt-get found; ensure iproute2/ethtool/curl are available on your distro."
  fi
}

detect_systemd_resolved(){
  if systemctl list-unit-files | grep -q '^systemd-resolved'; then
    return 0
  else
    return 1
  fi
}

apply_dns_systemd_resolved(){
  dns="$1"
  log "Configuring systemd-resolved to use DNS=$dns"
  backup_file /etc/systemd/resolved.conf
  cat >/etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=$dns
#FallbackDNS=
EOF
  systemctl restart systemd-resolved || true
  # ensure /etc/resolv.conf points to resolved
  if [ -f /run/systemd/resolve/resolv.conf ]; then
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  elif [ -f /run/systemd/resolve/stub-resolv.conf ]; then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  fi
}

apply_dns_resolvconf(){
  dns="$1"
  log "Writing /etc/resolv.conf with DNS=$dns"
  backup_file /etc/resolv.conf
  cat >/etc/resolv.conf <<EOF
# Managed by bbr2-super-english.sh
nameserver $dns
options rotate
EOF
}

apply_mtu_all_ifaces(){
  mtu="$1"
  log "Applying MTU=$mtu to all non-loopback/non-virtual interfaces..."
  for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
    case "$iface" in
      lo|docker*|veth*|br-*|tun*|tap*|wg*|virbr*|lxc*|virbr*)
        continue
        ;;
    esac
    ip link set dev "$iface" mtu "$mtu" 2>/dev/null || true
  done
  echo "$mtu" > "$MTU_VALUE_FILE"
}

generate_sysctl(){
  cat >"$SYSCTL_CONF" <<'EOF'
# bbr2-super tuning - safe defaults for gaming/streaming
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 250000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
# congestion control line will be set by the script to bbr2 (or bbr fallback)
net.ipv4.tcp_congestion_control = bbr2
EOF
}

create_apply_script(){
  cat >"$APPLY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -e
DNS_FILE="/etc/bbr_dns_value"
MTU_FILE="/etc/bbr_mtu_value"
# Apply sysctl
/sbin/sysctl --system || true
# Apply MTU
if [ -f "$MTU_FILE" ]; then
  mtu="$(cat "$MTU_FILE")"
  for i in $(ip -o link show | awk -F': ' '{print $2}'); do
    case "$i" in
      lo|docker*|veth*|br-*|tun*|tap*|wg*|virbr*|lxc*)
        continue
        ;;
    esac
    /sbin/ip link set dev "$i" mtu "$mtu" 2>/dev/null || true
  done
fi
# Apply DNS
if [ -f "$DNS_FILE" ]; then
  dns="$(cat "$DNS_FILE")"
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    sed -i '/^DNS=/d' /etc/systemd/resolved.conf 2>/dev/null || true
    echo -e "[Resolve]\nDNS=$dns\n" >/etc/systemd/resolved.conf
    systemctl restart systemd-resolved || true
    if [ -f /run/systemd/resolve/resolv.conf ]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
  else
    cat >/etc/resolv.conf <<EOF
# Managed by bbr2-super-english.sh
nameserver $dns
options rotate
EOF
  fi
fi
EOF
  chmod +x "$APPLY_SCRIPT"
}

create_systemd_service(){
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Apply BBR2 / MTU / DNS settings at network-online
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$APPLY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now bbr2-apply.service || true
}

check_bbr2_module(){
  if modinfo tcp_bbr2 &>/dev/null; then
    return 0
  fi
  if [ -d /sys/module/tcp_bbr2 ]; then
    return 0
  fi
  # also check kernel config if present
  if [ -f "/boot/config-$(uname -r)" ] && grep -q "CONFIG_TCP_CONG_BBR2=y" "/boot/config-$(uname -r)" ; then
    return 0
  fi
  return 1
}

enable_bbr2_or_bbr(){
  # Try to enable BBR2. If not available, fallback to BBR (classic) and inform the user.
  generate_sysctl
  if check_bbr2_module; then
    log "BBR2 support detected in kernel, attempting to load and enable it..."
    modprobe tcp_bbr2 2>/dev/null || true
    sysctl --system || true
    log "Attempted to enable BBR2. Use 'Show status' to verify."
    return 0
  else
    log "BBR2 not found in this kernel. Falling back to classic BBR."
    sed -i 's/net.ipv4.tcp_congestion_control = bbr2/net.ipv4.tcp_congestion_control = bbr/' "$SYSCTL_CONF"
    modprobe tcp_bbr 2>/dev/null || true
    sysctl --system || true
    log "Classic BBR enabled (if supported). To get real BBR2, you need a kernel with tcp_bbr2 support."
    return 1
  fi
}

show_status(){
  echo "=== Status ==="
  echo "Date: $(date)"
  echo "Kernel: $(uname -r)"
  echo "Architecture: $(uname -m)"
  echo
  echo "Sysctl tuning file: $SYSCTL_CONF"
  [ -f "$SYSCTL_CONF" ] && sed -n '1,200p' "$SYSCTL_CONF" || echo "(file not found)"
  echo
  echo "Active congestion control:"
  sysctl net.ipv4.tcp_congestion_control || true
  echo
  echo "Loaded modules:"
  lsmod | egrep 'tcp_bbr2|tcp_bbr' || echo "(none loaded)"
  echo
  echo "MTU file: $( [ -f $MTU_VALUE_FILE ] && cat $MTU_VALUE_FILE || echo '(none)' )"
  echo "DNS file: $( [ -f $DNS_VALUE_FILE ] && cat $DNS_VALUE_FILE || echo '(none)' )"
  echo
  echo "/etc/resolv.conf head:"
  head -n 20 /etc/resolv.conf || true
  echo
  echo "systemd-resolved active?: $(systemctl is-active systemd-resolved 2>/dev/null || echo inactive)"
  echo
  echo "To inspect kernel support for bbr2 run: modinfo tcp_bbr2 || grep -i bbr2 /boot/config-$(uname -r)"
  echo "================"
}

install_flow(){
  ensure_root
  log "Starting BBR2-super install flow..."
  do_backup
  install_prereqs
  # Save defaults
  echo "$DEFAULT_DNS" > "$DNS_VALUE_FILE"
  echo "$DEFAULT_MTU" > "$MTU_VALUE_FILE"
  # Apply DNS
  if detect_systemd_resolved; then
    apply_dns_systemd_resolved "$DEFAULT_DNS"
  else
    apply_dns_resolvconf "$DEFAULT_DNS"
  fi
  # Apply MTU now
  apply_mtu_all_ifaces "$DEFAULT_MTU"
  # create sysctl and try enable bbr2/bbr
  enable_bbr2_or_bbr
  # create apply script and service for persistence
  create_apply_script
  create_systemd_service
  log "Install flow finished. Check status with option 'Show status'."
  log "If kernel lacks tcp_bbr2, see menu option 'Kernel helper' for guidance."
}

uninstall_flow(){
  ensure_root
  log "Starting uninstall: remove generated files and try restore backups..."
  systemctl disable --now bbr2-apply.service 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$APPLY_SCRIPT" "$SYSCTL_CONF" "$MTU_VALUE_FILE" "$DNS_VALUE_FILE" || true
  systemctl daemon-reload || true
  if [ -d "$BACKUP_DIR" ]; then
    log "Restoring any backup files found in $BACKUP_DIR ..."
    for f in "$BACKUP_DIR"/*; do
      base="$(basename "$f")"
      case "$base" in
        resolv.conf) cp -a "$f" /etc/resolv.conf || true ;;
        resolved.conf) cp -a "$f" /etc/systemd/resolved.conf || true ;;
        *) cp -a "$f" "/etc/$base" 2>/dev/null || true ;;
      esac
    done
    log "Backups restored (where present)."
  else
    log "No backup dir found at $BACKUP_DIR"
  fi
  /sbin/sysctl --system || true
  log "Uninstall finished."
}

set_dns_manual(){
  ensure_root
  read -rp "Enter new DNS (example: 1.1.1.1): " dns
  if [ -z "$dns" ]; then
    echo "Empty input. Aborted."
    return 1
  fi
  echo "$dns" > "$DNS_VALUE_FILE"
  if detect_systemd_resolved; then
    apply_dns_systemd_resolved "$dns"
  else
    apply_dns_resolvconf "$dns"
  fi
  log "DNS set to $dns"
}

set_mtu_manual(){
  ensure_root
  read -rp "Enter new MTU (example: 1420): " mtu
  if ! [[ "$mtu" =~ ^[0-9]+$ ]]; then
    echo "Invalid MTU value."
    return 1
  fi
  echo "$mtu" > "$MTU_VALUE_FILE"
  apply_mtu_all_ifaces "$mtu"
  log "MTU applied: $mtu"
}

kernel_helper(){
  # Explain and offer simple automated assist (non-invasive)
  echo "=== Kernel helper for BBR2 ==="
  echo "BBR2 requires kernel support (tcp_bbr2 module)."
  echo
  if check_bbr2_module; then
    echo "tcp_bbr2 appears available on this system."
    echo "No kernel upgrade needed."
    return
  fi
  echo "tcp_bbr2 not detected in this kernel."
  echo "Options:"
  echo "  1) Show instructions to upgrade kernel manually (recommended to use provider console)"
  echo "  2) Attempt to install a newer Ubuntu generic/hwe kernel via apt (risky on remote servers)"
  echo "  3) Skip (keep classic BBR fallback)"
  read -rp "Choose option (1/2/3): " kopt
  case "$kopt" in
    1)
      cat <<INSTR
Manual upgrade instructions (recommended safe approach):
 - Use your provider console if network may risk being lost.
 - On Ubuntu, prefer installing a tested generic or HWE kernel:
   e.g. apt update && apt install linux-image-generic linux-headers-generic
 - For mainline kernels, you can download .deb packages and install with dpkg -i.
 - After kernel install, reboot and run: modinfo tcp_bbr2 || grep -i bbr2 /boot/config-$(uname -r)
INSTR
      ;;
    2)
      echo "Attempting to install 'linux-image-generic' via apt. This may change your kernel and require reboot."
      read -rp "Proceed with apt install linux-image-generic? (y/N): " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if command -v apt-get >/dev/null 2>&1; then
          apt-get update -y
          DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-generic linux-headers-generic || echo "apt install failed or not supported on this release."
          echo "If kernel packages were installed, reboot is required. After reboot check for tcp_bbr2."
        else
          echo "apt not found. Aborting option 2."
        fi
      else
        echo "Aborted."
      fi
      ;;
    *)
      echo "Skipping kernel actions. System will continue to use classic BBR if available."
      ;;
  esac
}

# Menu
menu(){
  ensure_root
  while true; do
    cat <<'MENU'

===== BBR2-SUPER (English) =====
1) Install / Apply BBR2 tuning (defaults: DNS=1.1.1.1, MTU=1420)
2) Uninstall / Restore (attempt to restore backups)
3) Set DNS manually
4) Set MTU manually
5) Show status / settings
6) Kernel helper (check BBR2 availability & guidance)
7) Reboot server
8) Exit
===============================
MENU
    read -rp "Your choice: " opt
    case "$opt" in
      1) install_flow ;;
      2) read -rp "Confirm full uninstall? (y/N): " yn; [[ $yn =~ ^[Yy]$ ]] && uninstall_flow || echo "Cancelled" ;;
      3) set_dns_manual ;;
      4) set_mtu_manual ;;
      5) show_status ;;
      6) kernel_helper ;;
      7) echo "Rebooting..."; sleep 1; reboot ;;
      8) echo "Exit."; exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

menu
