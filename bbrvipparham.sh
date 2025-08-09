#!/usr/bin/env bash
# bbrvipparham.sh - BBR2 Ultra / TCP Turbo (Parham edition)
# Usage: sudo bash bbrvipparham.sh
# Installs/Manages real BBR2 (tries hard), falls back to classic BBR if needed,
# manages DNS (default 1.1.1.1), MTU (default 1420), persistence across reboot,
# logging, backup & safe uninstall.
set -euo pipefail
LANG=C.UTF-8

# ---------- Configurable paths & defaults ----------
INSTALL_DIR="/etc/bbrvip"
LOGFILE="/var/log/bbrvip.log"
BACKUP_DIR="/etc/bbrvip/backups_$(date +%s)"
SYSCTL_CONF="$INSTALL_DIR/99-bbrvip-sysctl.conf"
APPLY_SCRIPT="$INSTALL_DIR/bbrvip-apply.sh"
SERVICE_FILE="/etc/systemd/system/bbrvip-apply.service"
DNS_VALUE_FILE="$INSTALL_DIR/dns.value"
MTU_VALUE_FILE="$INSTALL_DIR/mtu.value"
CONFIG_FILE="$INSTALL_DIR/config.env"

DEFAULT_DNS="1.1.1.1"
DEFAULT_MTU="1420"

# ---------- helpers ----------
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
ensure_root() { if [ "$EUID" -ne 0 ]; then echo "Run as root"; exit 1; fi }
mkdirs() { mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"; touch "$LOGFILE"; chmod 600 "$LOGFILE"; }

backup_if_exists() {
  local f="$1"
  if [ -e "$f" ]; then
    cp -a "$f" "$BACKUP_DIR/" || true
  fi
}
detect_default_iface() {
  # try ip route default
  local ifa
  ifa=$(ip route 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}' | head -n1)
  if [ -n "$ifa" ]; then echo "$ifa" && return 0; fi
  # fallback: first non-loopback
  ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1
}

# ---------- Backup current / important files ----------
do_backup() {
  log "Creating backup directory: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  backup_if_exists /etc/resolv.conf
  backup_if_exists /etc/systemd/resolved.conf
  backup_if_exists /etc/netplan || true
  backup_if_exists /etc/sysctl.conf
  backup_if_exists /etc/hosts
  backup_if_exists "$SERVICE_FILE" || true
  backup_if_exists "$SYSCTL_CONF" || true
  log "Backup complete (if files existed)."
}

# ---------- Prereqs ----------
install_prereqs() {
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing prerequisites via apt..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 ethtool curl ca-certificates procps || true
  else
    log "Package manager apt not found. Ensure iproute2/ethtool/curl exist."
  fi
}

# ---------- Sysctl generation (full tuned) ----------
generate_sysctl_conf() {
  log "Writing sysctl tuning to $SYSCTL_CONF"
  cat > "$SYSCTL_CONF" <<'EOF'
# BBRVIP - Parham tuned sysctl for gaming/streaming
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr2
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
# Keep timestamps and selective ack
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
# Keep NAT/forwarding sane (not changing by default)
EOF
  # apply immediately
  sysctl --system || true
}

# ---------- BBR2 detection & enable ----------
check_bbr2_present() {
  # returns 0 if kernel supports tcp_bbr2
  if modinfo tcp_bbr2 &>/dev/null; then return 0; fi
  if [ -d /sys/module/tcp_bbr2 ]; then return 0; fi
  if [ -f "/boot/config-$(uname -r)" ] && grep -q -E "CONFIG_TCP_CONG_BBR2=(y|m)" "/boot/config-$(uname -r)"; then return 0; fi
  return 1
}

enable_bbr2() {
  log "Attempting to enable BBR2..."
  # ensure sysctl file sets bbr2 (generate then adjust if needed)
  generate_sysctl_conf
  # try load module if available
  if check_bbr2_present; then
    modprobe tcp_bbr2 2>/dev/null || true
    sysctl --system || true
    log "BBR2 module present. Please verify with 'modinfo tcp_bbr2' and 'sysctl net.ipv4.tcp_congestion_control'"
    return 0
  else
    log "BBR2 not found in this kernel. Falling back to classic BBR where possible."
    # switch to classic bbr in sysctl file
    sed -i 's/net.ipv4.tcp_congestion_control = bbr2/net.ipv4.tcp_congestion_control = bbr/' "$SYSCTL_CONF" || true
    modprobe tcp_bbr 2>/dev/null || true
    sysctl --system || true
    return 1
  fi
}

# ---------- Apply DNS ----------
apply_dns() {
  local dns="$1"
  if [ -z "$dns" ]; then dns="$DEFAULT_DNS"; fi
  echo "$dns" > "$DNS_VALUE_FILE"
  # prefer modifying systemd-resolved if active
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    log "Configuring systemd-resolved to use DNS=$dns"
    backup_if_exists /etc/systemd/resolved.conf
    cat >/etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=$dns
#FallbackDNS=
EOF
    systemctl restart systemd-resolved || true
    if [ -f /run/systemd/resolve/resolv.conf ]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
    fi
  else
    log "Writing /etc/resolv.conf with DNS=$dns"
    backup_if_exists /etc/resolv.conf
    cat >/etc/resolv.conf <<EOF
# Managed by bbrvip
nameserver $dns
options rotate
EOF
  fi
  log "DNS applied: $dns"
}

# ---------- Apply MTU ----------
apply_mtu_all() {
  local mtu="$1"
  if ! [[ "$mtu" =~ ^[0-9]+$ ]]; then
    log "Invalid MTU: $mtu"; return 1
  fi
  echo "$mtu" > "$MTU_VALUE_FILE"
  log "Applying MTU=$mtu to all physical/normal interfaces..."
  for ifc in $(ip -o link show | awk -F': ' '{print $2}'); do
    case "$ifc" in
      lo|docker*|veth*|br-*|tun*|tap*|wg*|virbr*|lxc*|vnet* ) continue ;;
    esac
    ip link set dev "$ifc" mtu "$mtu" 2>/dev/null || log "Could not set MTU on $ifc"
  done
}

# ---------- Persistence: apply script & systemd service ----------
create_apply_script_and_service() {
  log "Creating apply script $APPLY_SCRIPT and systemd service $SERVICE_FILE"
  cat > "$APPLY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Reapply sysctl (system-wide)
/sbin/sysctl --system || true
DNS_FILE="/etc/bbrvip/dns.value"
MTU_FILE="/etc/bbrvip/mtu.value"
# Reapply MTU
if [ -f "$MTU_FILE" ]; then
  mtu="$(cat "$MTU_FILE")"
  for ifc in $(ip -o link show | awk -F': ' '{print $2}'); do
    case "$ifc" in
      lo|docker*|veth*|br-*|tun*|tap*|wg*|virbr*|lxc*|vnet*)
        continue
        ;;
    esac
    /sbin/ip link set dev "$ifc" mtu "$mtu" 2>/dev/null || true
  done
fi
# Reapply DNS
if [ -f "$DNS_FILE" ]; then
  dns="$(cat "$DNS_FILE")"
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    sed -i '/^DNS=/d' /etc/systemd/resolved.conf 2>/dev/null || true
    echo -e "[Resolve]\nDNS=$dns\n" >/etc/systemd/resolved.conf
    systemctl restart systemd-resolved || true
    if [ -f /run/systemd/resolve/resolv.conf ]; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf || true
    fi
  else
    cat >/etc/resolv.conf <<EOF2
# Managed by bbrvip
nameserver $dns
options rotate
EOF2
  fi
fi
EOF
  chmod +x "$APPLY_SCRIPT"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=BBRVIP apply service - reapply sysctl/mtu/dns at network-online
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$APPLY_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || true
  systemctl enable --now bbrvip-apply.service || true
}

# ---------- Uninstall ----------
uninstall_all() {
  log "Uninstall: disabling service and removing generated files"
  systemctl disable --now bbrvip-apply.service 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$APPLY_SCRIPT" "$SYSCTL_CONF" "$DNS_VALUE_FILE" "$MTU_VALUE_FILE" "$CONFIG_FILE" || true
  systemctl daemon-reload || true
  # restore backups if present
  if [ -d "$BACKUP_DIR" ]; then
    log "Attempting to restore any backed up files from $BACKUP_DIR"
    for f in "$BACKUP_DIR"/*; do
      base=$(basename "$f")
      case "$base" in
        resolv.conf) cp -a "$f" /etc/resolv.conf || true ;;
        resolved.conf) cp -a "$f" /etc/systemd/resolved.conf || true ;;
        sysctl.conf) cp -a "$f" /etc/sysctl.conf || true ;;
        *) cp -a "$f" "/etc/$base" 2>/dev/null || true ;;
      esac
    done
    log "Restoration attempted."
  else
    log "No backup dir found; nothing restored."
  fi
  log "Uninstall finished."
}

# ---------- Status ----------
show_status() {
  echo "---- BBRVIP Status ----"
  echo "Date: $(date)"
  echo "Kernel: $(uname -r)"
  echo "Arch: $(uname -m)"
  echo
  echo "Sysctl file: $SYSCTL_CONF"
  [ -f "$SYSCTL_CONF" ] && sed -n '1,200p' "$SYSCTL_CONF" || echo "(not present)"
  echo
  echo "Active congestion control:"
  sysctl net.ipv4.tcp_congestion_control || true
  echo
  echo "Loaded modules (bbr2 / bbr):"
  lsmod | egrep 'tcp_bbr2|tcp_bbr' || true
  echo
  echo "MTU value file: $( [ -f "$MTU_VALUE_FILE" ] && cat "$MTU_VALUE_FILE" || echo '(none)' )"
  echo "DNS value file: $( [ -f "$DNS_VALUE_FILE" ] && cat "$DNS_VALUE_FILE" || echo '(none)' )"
  echo
  echo "/etc/resolv.conf (head):"
  head -n 20 /etc/resolv.conf || true
  echo
  echo "systemd-resolved active?: $(systemctl is-active systemd-resolved 2>/dev/null || echo inactive)"
  echo "Service status: $(systemctl is-enabled bbrvip-apply.service 2>/dev/null || echo disabled)"
  echo "Log tail:"
  tail -n 20 "$LOGFILE" || true
  echo "-----------------------"
}

# ---------- Kernel helper (guidance only) ----------
kernel_helper() {
  echo "=== Kernel helper for BBR2 ==="
  if check_bbr2_present; then
    echo "tcp_bbr2 appears present on this kernel. No kernel upgrade required."
    return
  fi
  echo "tcp_bbr2 not detected. Options (manual recommended):"
  echo "1) Use provider console + install tested Ubuntu generic/HWE kernel via apt"
  echo "2) Install mainline kernel packages (risky) — not automated here"
  echo "3) Keep classic BBR fallback (already applied)"
  echo
  echo "If you want, you can choose option 1 to attempt 'apt install linux-image-generic' (may change kernel & require reboot)."
  read -rp "Choose 1 to attempt apt-based generic kernel install, anything else to skip: " kopt
  if [ "$kopt" = "1" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      read -rp "Proceed with apt install linux-image-generic linux-headers-generic? (y/N): " c
      if [[ "$c" =~ ^[Yy]$ ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-generic linux-headers-generic || log "apt install failed"
        log "Kernel packages installed (if available). Reboot required to use new kernel."
      else
        echo "Aborted."
      fi
    else
      echo "apt not available on this platform. Manual kernel install required."
    fi
  else
    echo "Skipping kernel install."
  fi
}

# ---------- Interactive menu ----------
main_menu() {
  ensure_root
  mkdirs
  while true; do
    cat <<'MENU'
BBRVIP - BBR2 Ultra / TCP Turbo (Parham)
1) Install / Apply optimized BBR2 (DNS=1.1.1.1, MTU=1420)
2) Uninstall / Revert changes
3) Change DNS manually
4) Change MTU manually
5) Show current status
6) Kernel helper (check & assist)
7) Reboot
0) Exit
MENU
    read -rp "Choose: " choice
    case "$choice" in
      1)
        do_backup
        install_prereqs
        # default save
        echo "$DEFAULT_DNS" > "$DNS_VALUE_FILE"
        echo "$DEFAULT_MTU" > "$MTU_VALUE_FILE"
        generate_sysctl_conf
        # try enable bbr2; fallback to bbr
        if enable_bbr2; then
          log "BBR2 enabled or attempted."
        else
          log "Fell back to classic BBR (if supported)."
        fi
        apply_dns "$DEFAULT_DNS"
        apply_mtu_all "$DEFAULT_MTU"
        create_apply_script_and_service
        log "Install flow done. Check status option."
        ;;
      2)
        read -rp "Confirm full uninstall and attempt to restore backups? (y/N): " yn
        if [[ "$yn" =~ ^[Yy]$ ]]; then
          uninstall_all
        else
          echo "Cancelled."
        fi
        ;;
      3)
        read -rp "Enter DNS to set (example: 1.1.1.1): " dnsval
        apply_dns "$dnsval"
        ;;
      4)
        read -rp "Enter MTU to set (example: 1420): " mtv
        apply_mtu_all "$mtv"
        ;;
      5) show_status ;;
      6) kernel_helper ;;
      7) echo "Rebooting..."; sleep 1; reboot ;;
      0) exit 0 ;;
      *) echo "Invalid option" ;;
    esac
    echo
    read -rp "Press Enter to continue..." || true
  done
}

# ---------- Auto-run if called with flags ----------
# Allow non-interactive mode via env vars, e.g.
# INSTALL=1 bash script -> installs using defaults
if [ "${INSTALL:-0}" = "1" ]; then
  ensure_root; mkdir -p "$INSTALL_DIR"; do_backup; install_prereqs
  echo "$DEFAULT_DNS" > "$DNS_VALUE_FILE"; echo "$DEFAULT_MTU" > "$MTU_VALUE_FILE"
  generate_sysctl_conf; enable_bbr2 || true; apply_dns "$DEFAULT_DNS"; apply_mtu_all "$DEFAULT_MTU"; create_apply_script_and_service
  log "Non-interactive install complete."
  exit 0
fi

# ---------- start ----------
main_menu
