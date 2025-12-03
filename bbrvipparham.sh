#!/usr/bin/env bash
# install.sh - Advanced WARP (wgcf) Manager with Cloudflare Multi-Endpoint & Multi-IP SOCKS5
# Combines ideas from:
#   - ParsaKSH/Warp-Multi-IP (multi WARP configs + Dante SOCKS5)
#   - yonggekkk/warp-yg CFwarp.sh (menu-based WARP manager)
# Focus:
#   - Ubuntu VPS
#   - Use Cloudflare WARP IPv4 as main server IP (for Xray core, etc.)
#   - Optionally create multiple WARP accounts with separate SOCKS5 proxies.

WGCF_BIN="/usr/local/bin/wgcf"
WGCF_DIR="/root/.wgcf"
WGCF_PROFILE="${WGCF_DIR}/wgcf-profile.conf"
WGCF_CONF="/etc/wireguard/wgcf.conf"
WG_IF="wgcf"

MULTI_DIR="/root/warp-multi"
DANTED_DIR="/etc/danted-multi"
SYSTEMD_DIR="/etc/systemd/system"

# ---------------- Colors ----------------
red(){ echo -e "\033[31m\033[01m$1\033[0m"; }
green(){ echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue(){ echo -e "\033[36m\033[01m$1\033[0m"; }
white(){ echo -e "\033[37m\033[01m$1\033[0m"; }

pause(){ read -rp "Press Enter to continue..." _; }

# ---------------- Basic checks ----------------
check_root() {
  if [[ $EUID -ne 0 ]]; then
    red "This script must be run as root."
    exit 1
  fi
}

check_os() {
  if ! grep -qi "ubuntu" /etc/os-release; then
    yellow "This script is mainly tested on Ubuntu. Continuing at your own risk."
  fi
}

# ---------------- Dependencies ----------------
install_deps_base() {
  blue "Updating package list and installing base dependencies (curl, wget, jq)..."
  apt-get update -y >/dev/null 2>&1
  apt-get install -y curl wget jq >/dev/null 2>&1
}

install_deps_wgcf() {
  blue "Installing WireGuard and resolvconf..."
  apt-get install -y wireguard wireguard-tools resolvconf >/dev/null 2>&1
}

install_deps_dante() {
  blue "Installing Dante SOCKS server for multi-IP proxies..."
  apt-get install -y dante-server >/dev/null 2>&1
}

# ---------------- wgcf install & base config ----------------
install_wgcf() {
  if command -v wgcf >/dev/null 2>&1; then
    green "wgcf is already installed."
    return
  fi

  blue "Downloading wgcf (amd64) from GitHub releases..."
  wget -O "$WGCF_BIN" "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_amd64" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    red "Failed to download wgcf binary."
    exit 1
  fi
  chmod +x "$WGCF_BIN"
  green "wgcf installed at $WGCF_BIN."
}

generate_wgcf_config() {
  if [[ -f "$WGCF_CONF" ]]; then
    yellow "Existing WireGuard config found at $WGCF_CONF."
    yellow "Skipping wgcf registration and generation."
    return
  fi

  blue "Registering a new WARP account with wgcf..."
  mkdir -p "$WGCF_DIR"
  cd "$WGCF_DIR" || exit 1

  yes | wgcf register >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    red "wgcf registration failed."
    exit 1
  fi
  green "wgcf registration successful."

  blue "Generating WireGuard profile with wgcf..."
  wgcf generate >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    red "wgcf generate failed."
    exit 1
  fi

  if [[ ! -f "$WGCF_PROFILE" ]]; then
    if [[ -f "${WGCF_DIR}/wgcf-profile.conf" ]]; then
      WGCF_PROFILE="${WGCF_DIR}/wgcf-profile.conf"
    else
      red "Cannot find wgcf-profile.conf after generation."
      exit 1
    fi
  fi

  mkdir -p /etc/wireguard
  cp "$WGCF_PROFILE" "$WGCF_CONF"
  chmod 600 "$WGCF_CONF"
  green "Base WARP WireGuard config created at $WGCF_CONF."
}

# ---------------- Cloudflare endpoint list ----------------
CF_IPS=(
  "1) Europe - Frankfurt   | 162.159.192.1:2408"
  "2) Europe - Amsterdam   | 188.114.97.3:2408"
  "3) Asia   - Singapore   | 162.159.195.1:2408"
  "4) Asia   - Japan       | 172.64.146.3:2408"
  "5) US     - New York    | 104.16.248.249:2408"
  "6) US     - Dallas      | 172.67.222.34:2408"
  "7) Custom Endpoint      | Enter IP:PORT manually"
)

choose_cf_ip() {
  echo
  blue "Cloudflare WARP Endpoint Selector"
  echo "-------------------------------------------"
  for i in "${CF_IPS[@]}"; do
    echo "$i"
  done
  echo "-------------------------------------------"
  read -rp "Choose an option (1-7): " choice

  case "$choice" in
    1) CF_ENDPOINT="162.159.192.1:2408" ;;
    2) CF_ENDPOINT="188.114.97.3:2408" ;;
    3) CF_ENDPOINT="162.159.195.1:2408" ;;
    4) CF_ENDPOINT="172.64.146.3:2408" ;;
    5) CF_ENDPOINT="104.16.248.249:2408" ;;
    6) CF_ENDPOINT="172.67.222.34:2408" ;;
    7)
      read -rp "Enter custom endpoint as IP:PORT (e.g. 162.159.192.1:2408): " custom_ep
      if [[ -z "$custom_ep" ]]; then
        red "Empty value is not allowed."
        return 1
      fi
      CF_ENDPOINT="$custom_ep"
      ;;
    *)
      red "Invalid choice."
      return 1
      ;;
  esac

  green "Selected Endpoint: $CF_ENDPOINT"
  return 0
}

backup_config() {
  if [[ -f "$WGCF_CONF" ]]; then
    TS=$(date +%Y%m%d-%H%M%S)
    cp "$WGCF_CONF" "${WGCF_CONF}.bak-${TS}"
    yellow "Backup created: ${WGCF_CONF}.bak-${TS}"
  fi
}

set_endpoint_and_routes_main() {
  if [[ ! -f "$WGCF_CONF" ]]; then
    red "WireGuard config $WGCF_CONF does not exist."
    return 1
  fi

  # Set Endpoint
  if grep -q "^Endpoint *= *" "$WGCF_CONF"; then
    sed -i "s/^Endpoint *= *.*/Endpoint = ${CF_ENDPOINT}/" "$WGCF_CONF"
  else
    sed -i "/^\[Peer\]/a Endpoint = ${CF_ENDPOINT}" "$WGCF_CONF"
  fi

  # Force all IPv4 + IPv6 through WARP
  if grep -q "^AllowedIPs *= *" "$WGCF_CONF"; then
    sed -i "s/^AllowedIPs *= *.*/AllowedIPs = 0.0.0.0\/0, ::\/0/" "$WGCF_CONF"
  else
    sed -i "/^\[Peer\]/a AllowedIPs = 0.0.0.0\/0, ::\/0" "$WGCF_CONF"
  fi

  green "Endpoint and AllowedIPs updated in $WGCF_CONF."
}

# ---------------- IP & status helpers ----------------
detect_ips() {
  IPV4_NOW=$(curl -4s --max-time 5 icanhazip.com 2>/dev/null)
  IPV6_NOW=$(curl -6s --max-time 5 icanhazip.com 2>/dev/null)
}

show_current_status() {
  echo "-------------------------------------------"
  blue "Current public IP addresses:"
  detect_ips
  echo "IPv4: ${IPV4_NOW:-N/A}"
  echo "IPv6: ${IPV6_NOW:-N/A}"
  echo "-------------------------------------------"
  if command -v wg >/dev/null 2>&1; then
    if wg show "$WG_IF" >/dev/null 2>&1; then
      green "WireGuard interface $WG_IF status:"
      wg show "$WG_IF"
    else
      yellow "WireGuard interface $WG_IF is not up."
    fi
  else
    yellow "wg command not found."
  fi

  echo "-------------------------------------------"
  blue "Cloudflare trace (if available):"
  curl -4s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | tail -n 10 || echo "trace failed"
  echo "-------------------------------------------"
}

enable_ip_forward() {
  sed -i 's/^#*net.ipv4.ip_forward *= *.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  green "IPv4 forwarding enabled."
}

restart_wg_main() {
  if [[ ! -f "$WGCF_CONF" ]]; then
    red "WireGuard config $WGCF_CONF not found. Cannot start wg-quick."
    return 1
  fi

  systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1
  systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1
  systemctl start "wg-quick@${WG_IF}"

  if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    green "Interface ${WG_IF} is up via wg-quick."
  else
    red "Failed to start wg-quick@${WG_IF}. Check logs:"
    journalctl -u "wg-quick@${WG_IF}" --no-pager | tail -n 30
    return 1
  fi
}

test_warp_route_main() {
  echo
  blue "Testing IPv4 after WARP activation..."
  sleep 3
  NEW_IPv4=$(curl -4s --max-time 8 icanhazip.com 2>/dev/null)
  echo "New public IPv4: ${NEW_IPv4:-N/A}"

  WARP_STATUS_V4=$(curl -4s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^warp=' | cut -d= -f2)
  echo "WARP status (IPv4): ${WARP_STATUS_V4:-unknown}"

  if [[ "$WARP_STATUS_V4" =~ ^on|plus$ ]]; then
    green "IPv4 traffic is going through Cloudflare WARP (good for Xray outbound)."
  else
    yellow "It seems WARP is not fully active for IPv4. Please check configuration."
  fi
}

enable_warp_main() {
  enable_ip_forward
  restart_wg_main
  test_warp_route_main
}

disable_warp_main() {
  blue "Stopping wg-quick@${WG_IF}..."
  systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1
  systemctl disable "wg-quick@${WG_IF}" >/dev/null 2>&1
  green "WARP (wg-quick@${WG_IF}) has been stopped and disabled."
}

uninstall_warp_main() {
  disable_warp_main
  blue "Removing main WARP configuration and wgcf files..."
  rm -f "$WGCF_CONF"
  rm -rf "$WGCF_DIR"
  if [[ -f "$WGCF_BIN" ]]; then
    rm -f "$WGCF_BIN"
  fi
  green "Main WARP and wgcf have been removed from this system."
}

# ---------------- Multi-IP (like Warp-Multi-IP) ----------------
multi_cleanup_all() {
  blue "Stopping and removing multi-IP WARP and Dante services..."
  for i in $(seq 1 8); do
    systemctl stop "wg-quick@wgcf${i}" 2>/dev/null
    systemctl disable "wg-quick@wgcf${i}" 2>/dev/null
    rm -f "/etc/wireguard/wgcf${i}.conf"
  done

  if [[ -d "$DANTED_DIR" ]]; then
    for svc in "$SYSTEMD_DIR"/danted-warp*.service; do
      [[ -e "$svc" ]] || continue
      name=$(basename "$svc")
      systemctl stop "$name" 2>/dev/null
      systemctl disable "$name" 2>/dev/null
      rm -f "$svc"
    done
    rm -rf "$DANTED_DIR"
  fi

  systemctl daemon-reload
  rm -rf "$MULTI_DIR"
  green "All multi-IP WARP configs and Dante services removed."
}

multi_generate() {
  install_deps_wgcf
  install_deps_dante
  install_wgcf

  mkdir -p "$MULTI_DIR"
  mkdir -p /etc/wireguard
  mkdir -p "$DANTED_DIR"

  blue "Generating multiple WARP accounts and WireGuard configs (like Warp-Multi-IP)..."
  # Number of interfaces / proxies
  local COUNT=5
  local BASE_IP="172.16.0"

  for i in $(seq 1 "$COUNT"); do
    local conf_path="/etc/wireguard/wgcf${i}.conf"
    local work_dir="${MULTI_DIR}/warp${i}"
    local table_id=$((51820 + i))
    local ip_addr="${BASE_IP}.$((i+1))"

    if [[ -f "$conf_path" ]]; then
      yellow "Config wgcf${i}.conf already exists, skipping generation."
      continue
    fi

    mkdir -p "$work_dir"
    cd "$work_dir" || exit 1

    rm -f wgcf-account.toml
    blue "Registering WARP account #${i}..."
    yes | wgcf register >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      red "wgcf register failed for account #${i}, skipping."
      continue
    fi

    wgcf generate >/dev/null 2>&1
    if [[ ! -f "wgcf-profile.conf" ]]; then
      red "wgcf-profile.conf not found for account #${i}, skipping."
      continue
    fi

    cp wgcf-profile.conf "$conf_path"
    chmod 600 "$conf_path"

    # Set private internal IP and policy routing table
    sed -i "s|^Address *=.*|Address = ${ip_addr}/32|" "$conf_path"

    # Add policy routing rules
    if ! grep -q "^Table *= *" "$conf_path"; then
      sed -i "/^\[Interface\]/a Table = ${table_id}\\nPostUp = ip rule add from ${ip_addr}/32 table ${table_id}\\nPostDown = ip rule del from ${ip_addr}/32 table ${table_id}" "$conf_path"
    fi

    green "Generated wgcf${i}.conf with internal IP ${ip_addr} and table ${table_id}."
  done

  # Reload WireGuard kernel module
  modprobe -r wireguard 2>/dev/null || true
  modprobe wireguard 2>/dev/null || true

  blue "Enabling wg-quick@wgcfN interfaces..."
  for i in $(seq 1 "$COUNT"); do
    systemctl enable "wg-quick@wgcf${i}" >/dev/null 2>&1
    systemctl restart "wg-quick@wgcf${i}" >/dev/null 2>&1
  done

  # Create Dante configs
  blue "Setting up Dante SOCKS5 proxies..."
  for i in $(seq 1 "$COUNT"); do
    local port=$((1080 + i))
    local ip="${BASE_IP}.$((i+1))"
    local conf_file="${DANTED_DIR}/danted-warp${i}.conf"
    cat >"$conf_file" <<EOF
logoutput: stderr
internal: 127.0.0.1 port = ${port}
external: ${ip}
user.privileged: root
user.unprivileged: nobody
clientmethod: none
socksmethod: none

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}
EOF

    local service_file="${SYSTEMD_DIR}/danted-warp${i}.service"
    cat >"$service_file" <<EOF
[Unit]
Description=Dante SOCKS proxy warp${i}
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/danted -f ${conf_file}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "danted-warp${i}" >/dev/null 2>&1
    systemctl restart "danted-warp${i}" >/dev/null 2>&1

    green "SOCKS5 proxy warp${i}: 127.0.0.1:${port} (external IP via wgcf${i})."
  done

  blue "Checking public IPs behind each SOCKS5 proxy..."
  for i in $(seq 1 "$COUNT"); do
    local port=$((1080 + i))
    local ip_raw
    ip_raw=$(curl -s --socks5 "127.0.0.1:${port}" --max-time 12 https://api.ipify.org || echo "error")
    echo "Proxy #${i} (127.0.0.1:${port}) → ${ip_raw}"
  done

  echo
  green "Multi-IP WARP + SOCKS5 setup completed."
  echo "You can use these SOCKS5 proxies in your tools or clients."
}

multi_list_status() {
  if [[ ! -d "$DANTED_DIR" ]]; then
    yellow "No multi-IP Dante configuration directory found at $DANTED_DIR."
    return
  fi
  echo "Existing multi-IP WARP SOCKS5 proxies:"
  for conf in "$DANTED_DIR"/danted-warp*.conf; do
    [[ -e "$conf" ]] || continue
    base=$(basename "$conf")
    idx=${base//[!0-9]/}
    port=$((1080 + idx))
    echo "  warp${idx}: SOCKS5 127.0.0.1:${port}, config=$conf"
  done
}

# ---------------- Menu actions ----------------
action_full_install_main() {
  install_deps_base
  install_deps_wgcf
  install_wgcf
  generate_wgcf_config
  choose_cf_ip || { pause; return; }
  backup_config
  set_endpoint_and_routes_main
  enable_warp_main
  pause
}

action_change_endpoint_main() {
  if [[ ! -f "$WGCF_CONF" ]]; then
    red "Main WARP config not found at $WGCF_CONF. Run full installation first."
    pause
    return
  fi
  choose_cf_ip || { pause; return; }
  backup_config
  set_endpoint_and_routes_main
  restart_wg_main
  test_warp_route_main
  pause
}

action_show_status_all() {
  show_current_status
  echo
  blue "Multi-IP SOCKS5 status:"
  multi_list_status
  pause
}

action_enable_only_main() {
  enable_warp_main
  pause
}

action_disable_only_main() {
  disable_warp_main
  pause
}

action_uninstall_all() {
  read -rp "This will uninstall main WARP and all multi-IP configs. Are you sure? (y/N): " ans
  case "$ans" in
    y|Y)
      uninstall_warp_main
      multi_cleanup_all
      ;;
    *)
      yellow "Uninstall cancelled."
      ;;
  esac
  pause
}

action_multi_generate() {
  read -rp "This will create multiple WARP accounts and SOCKS5 proxies. Continue? (y/N): " ans
  case "$ans" in
    y|Y)
      multi_generate
      ;;
    *)
      yellow "Multi-IP generation cancelled."
      ;;
  esac
  pause
}

action_multi_cleanup() {
  read -rp "This will remove ALL multi-IP WARP configs and Dante proxies. Continue? (y/N): " ans
  case "$ans" in
    y|Y) multi_cleanup_all ;;
    *) yellow "Cleanup cancelled." ;;
  esac
  pause
}

# ---------------- Main menu ----------------
show_menu() {
  clear
  blue "==============================================="
  blue "    Advanced WARP Multi Endpoint Manager       "
  blue " (Ubuntu + wgcf + Cloudflare + Multi-IP mode)  "
  blue "==============================================="
  echo
  white "1) Full install / reinstall main WARP (wgcf + WireGuard + Endpoint + routing)"
  white "2) Change Cloudflare Endpoint for main WARP"
  white "3) Show current status (public IP, wg, WARP trace, multi-IP proxies)"
  white "4) Enable main WARP (set default IPv4 via WARP - good for Xray)"
  white "5) Disable main WARP"
  white "6) Generate multiple WARP accounts + SOCKS5 proxies (multi-IP, like Warp-Multi-IP)"
  white "7) List / check multi-IP SOCKS5 proxies"
  white "8) Remove all multi-IP WARP configs and proxies"
  white "9) Uninstall everything (main WARP + multi-IP + wgcf)"
  white "0) Exit"
  echo
  read -rp "Choose an option [0-9]: " menu_choice
}

main() {
  check_root
  check_os
  install_deps_base

  while true; do
    show_menu
    case "$menu_choice" in
      1) action_full_install_main ;;
      2) action_change_endpoint_main ;;
      3) action_show_status_all ;;
      4) action_enable_only_main ;;
      5) action_disable_only_main ;;
      6) action_multi_generate ;;
      7) multi_list_status; pause ;;
      8) action_multi_cleanup ;;
      9) action_uninstall_all ;;
      0) green "Goodbye!"; exit 0 ;;
      *) red "Invalid option."; pause ;;
    esac
  done
}

main "$@"
