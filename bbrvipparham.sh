#!/usr/bin/env bash
# install.sh - Multi WARP + Multi SOCKS5 generator (clean version)
# Inspired by Parsa's warp-multi script, but rewritten from scratch in pure Bash.

set -euo pipefail

NUM_PROFILES=8                # how many WARP profiles / SOCKS proxies to create
BASE_INTERNAL_NET="172.16.0"  # base internal network for wgcf interfaces
WGCF_BIN="/usr/local/bin/wgcf"
CONF_ROOT="/etc/wireguard"
WORK_ROOT="/root/warp-confs"
DANTED_ROOT="/etc/danted-multi"
SYSTEMD_DIR="/etc/systemd/system"

# Different Cloudflare WARP IPv4 endpoints (different locations)
CF_ENDPOINTS=(
  "162.159.192.1:2408"  # Europe - Frankfurt
  "188.114.97.3:2408"   # Europe - Amsterdam
  "162.159.195.1:2408"  # Asia   - Singapore
  "172.64.146.3:2408"   # Asia   - Japan
  "104.16.248.249:2408" # US     - New York
  "172.67.222.34:2408"  # US     - Dallas
)

# ---------- color helpers ----------
red()   { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue()  { echo -e "\033[36m\033[01m$1\033[0m"; }

pause() { read -rp "Press Enter to continue..." _; }

# ---------- root check ----------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    red "This script must be run as root."
    exit 1
  fi
}

# ---------- cleanup ----------
cleanup_all() {
  echo
  yellow "Cleaning up existing WARP configs, interfaces and Dante services..."

  # Stop and disable Dante services
  if [[ -d "$DANTED_ROOT" ]]; then
    for svc in "$SYSTEMD_DIR"/danted-warp*.service; do
      [[ -e "$svc" ]] || continue
      name=$(basename "$svc")
      systemctl stop "$name" 2>/dev/null || true
      systemctl disable "$name" 2>/dev/null || true
      rm -f "$svc"
    done
    rm -rf "$DANTED_ROOT"
  fi

  # Stop wgcfX interfaces and remove configs
  for i in $(seq 1 32); do
    systemctl stop "wg-quick@wgcf${i}" 2>/dev/null || true
    systemctl disable "wg-quick@wgcf${i}" 2>/dev/null || true
    rm -f "${CONF_ROOT}/wgcf${i}.conf"
  done

  # Remove any stray wireguard interfaces
  for dev in $(ip -o link show | awk -F': ' '{print $2}' | grep '^wg' || true); do
    wg-quick down "$dev" 2>/dev/null || ip link delete "$dev" 2>/dev/null || true
  done

  rm -rf "$WORK_ROOT"

  systemctl daemon-reload
  modprobe -r wireguard 2>/dev/null || true

  green "Cleanup completed."
}

# ---------- dependencies ----------
install_deps() {
  blue "Updating APT and installing dependencies..."
  apt-get update -y >/dev/null 2>&1
  apt-get install -y wireguard wireguard-tools resolvconf curl jq dante-server unzip >/dev/null 2>&1
  green "Dependencies installed."
}

install_wgcf() {
  if command -v wgcf >/dev/null 2>&1; then
    green "wgcf is already installed."
    return
  fi

  blue "Installing wgcf..."
  # Using wgcf official binary for amd64. Adjust for other architectures if needed.
  wget -O "$WGCF_BIN" "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_amd64" >/dev/null 2>&1
  chmod +x "$WGCF_BIN"
  green "wgcf installed at $WGCF_BIN."
}

# ---------- helper: assign CF endpoint per index ----------
get_endpoint_for_index() {
  local idx=$1
  local n=${#CF_ENDPOINTS[@]}
  local arr_idx=$(( (idx - 1) % n ))
  echo "${CF_ENDPOINTS[$arr_idx]}"
}

# ---------- generate N WARP configs ----------
generate_warp_profiles() {
  blue "Creating working directory at $WORK_ROOT ..."
  mkdir -p "$WORK_ROOT"
  cd "$WORK_ROOT"

  mkdir -p "$CONF_ROOT"

  blue "Generating ${NUM_PROFILES} WARP profiles and WireGuard configs..."

  for i in $(seq 1 "$NUM_PROFILES"); do
    local_conf="${CONF_ROOT}/wgcf${i}.conf"
    local_dir="${WORK_ROOT}/warp${i}"

    if [[ -f "$local_conf" ]]; then
      yellow "  Config wgcf${i}.conf already exists, skipping generation."
      continue
    fi

    mkdir -p "$local_dir"
    cd "$local_dir"

    rm -f wgcf-account.toml wgcf-profile.conf

    blue "  [${i}/${NUM_PROFILES}] Registering WARP account..."
    wgcf register --accept-tos >/dev/null 2>&1 || {
      red "    wgcf register failed for profile ${i}, skipping."
      cd "$WORK_ROOT"
      continue
    }

    wgcf generate >/dev/null 2>&1 || {
      red "    wgcf generate failed for profile ${i}, skipping."
      cd "$WORK_ROOT"
      continue
    }

    if [[ ! -f wgcf-profile.conf ]]; then
      red "    wgcf-profile.conf missing for profile ${i}, skipping."
      cd "$WORK_ROOT"
      continue
    fi

    cp wgcf-profile.conf "$local_conf"
    chmod 600 "$local_conf"

    # Assign internal IP and routing table
    ip_suffix=$((i + 1))
    ip_addr="${BASE_INTERNAL_NET}.${ip_suffix}"
    table_id=$((51820 + i))

    # Replace Address line robustly (assumes one IPv4 Address line)
    sed -i -E "s|^Address *=.*|Address = ${ip_addr}/32|" "$local_conf"

    # Set unique CF endpoint (different location)
    cf_ep=$(get_endpoint_for_index "$i")
    sed -i -E "s|^Endpoint *=.*|Endpoint = ${cf_ep}|" "$local_conf"

    # Add routing table + policy rules if not already present
    if ! grep -q "^Table *=" "$local_conf"; then
      sed -i "/^\[Interface\]/a Table = ${table_id}\nPostUp = ip rule add from ${ip_addr}/32 table ${table_id}\nPostDown = ip rule del from ${ip_addr}/32 table ${table_id}" "$local_conf"
    fi

    green "    Created wgcf${i}.conf (IP ${ip_addr}, table ${table_id}, Endpoint ${cf_ep})"

    cd "$WORK_ROOT"
  done

  blue "Reloading WireGuard kernel module..."
  modprobe -r wireguard 2>/dev/null || true
  modprobe wireguard 2>/dev/null || true

  blue "Bringing up wgcfX interfaces..."
  for i in $(seq 1 "$NUM_PROFILES"); do
    if [[ -f "${CONF_ROOT}/wgcf${i}.conf" ]]; then
      systemctl enable "wg-quick@wgcf${i}" >/dev/null 2>&1 || true
      systemctl restart "wg-quick@wgcf${i}" >/dev/null 2>&1 || true
    fi
  done

  green "WireGuard interfaces started."
}

# ---------- setup Dante for each WARP profile ----------
setup_dante() {
  blue "Setting up Dante SOCKS5 proxies..."
  mkdir -p "$DANTED_ROOT"

  for i in $(seq 1 "$NUM_PROFILES"); do
    local_conf="${CONF_ROOT}/wgcf${i}.conf"
    [[ -f "$local_conf" ]] || { yellow "  wgcf${i}.conf not found, skipping Dante for ${i}."; continue; }

    port=$((1080 + i))
    ip_suffix=$((i + 1))
    internal_ip="${BASE_INTERNAL_NET}.${ip_suffix}"

    d_conf="${DANTED_ROOT}/danted-warp${i}.conf"
    d_service="${SYSTEMD_DIR}/danted-warp${i}.service"

    cat >"$d_conf" <<EOF
logoutput: stderr
internal: 127.0.0.1 port = ${port}
external: ${internal_ip}
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

    cat >"$d_service" <<EOF
[Unit]
Description=Dante SOCKS proxy warp${i}
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/danted -f ${d_conf}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "danted-warp${i}" >/dev/null 2>&1 || true
    systemctl restart "danted-warp${i}" >/dev/null 2>&1 || true

    green "  Dante proxy warp${i} -> SOCKS5 127.0.0.1:${port} (external via ${internal_ip})"
  done
}

# ---------- test uniqueness of public IPs ----------
check_unique_ips() {
  blue "Checking public IPs via each SOCKS5 proxy for uniqueness..."

  while true; do
    modprobe wireguard 2>/dev/null || true

    declare -A ip_map
    declare -A proxy_ips
    all_unique=true

    echo
    blue "Current proxy IPs:"
    for i in $(seq 1 "$NUM_PROFILES"); do
      port=$((1080 + i))

      # restart services to be sure
      systemctl restart "wg-quick@wgcf${i}" 2>/dev/null || true
      systemctl restart "danted-warp${i}" 2>/dev/null || true

      sleep 5

      ip_raw=$(curl -s --max-time 15 --socks5 "127.0.0.1:${port}" https://api.ipify.org || echo "")
      if [[ "$ip_raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip="$ip_raw"
      else
        ip="error"
      fi

      echo "  wgcf${i} (SOCKS 127.0.0.1:${port}) → ${ip}"
      proxy_ips[$i]="$ip"

      if [[ "$ip" == "error" ]]; then
        all_unique=false
      elif [[ -n "${ip_map[$ip]:-}" ]]; then
        all_unique=false
      fi

      ip_map[$ip]=1
    done

    if $all_unique; then
      green "All proxies have unique and valid public IPs."
      echo
      echo "SOCKS5 proxies (unique IPs):"
      for i in $(seq 1 "$NUM_PROFILES"); do
        port=$((1080 + i))
        echo "  wgcf${i} → SOCKS5 127.0.0.1:${port}"
      done
      break
    fi

    echo
    yellow "Some proxies have duplicate or invalid IPs."
    read -rp "Do you want to try again (restart interfaces & wait)? (y/n): " ans
    ans=${ans,,}  # to lowercase
    if [[ "$ans" != "y" ]]; then
      echo
      green "Returning only proxies with unique, non-error IPs:"
      for i in $(seq 1 "$NUM_PROFILES"); do
        port=$((1080 + i))
        ip="${proxy_ips[$i]}"
        if [[ "$ip" != "error" && "${ip_map[$ip]}" -eq 1 ]]; then
          echo "  wgcf${i} → SOCKS5 127.0.0.1:${port}  (IP: ${ip})"
        fi
      done
      break
    fi

    blue "Restarting all WARP interfaces, then waiting 30 seconds..."
    for i in $(seq 1 "$NUM_PROFILES"); do
      if ip link show "wgcf${i}" &>/dev/null; then
        wg-quick down "wgcf${i}" 2>/dev/null || ip link delete "wgcf${i}" 2>/dev/null || true
      fi
      systemctl restart "danted-warp${i}" 2>/dev/null || true
    done

    sleep 30
    modprobe -r wireguard 2>/dev/null || true
  done
}

# ---------- main ----------
main() {
  require_root

  echo "==============================================="
  echo " Multi WARP + Multi SOCKS5 Auto Installer"
  echo "==============================================="

  read -rp "Do you want to remove ALL existing configs and proxies first? (y/n): " cleanup_ans
  cleanup_ans=${cleanup_ans,,}
  if [[ "$cleanup_ans" == "y" ]]; then
    cleanup_all
  else
    yellow "Skipping cleanup of old configs."
  fi

  install_deps
  install_wgcf
  generate_warp_profiles
  setup_dante
  check_unique_ips

  echo
  green "All done!"
  echo "You can now use the generated SOCKS5 proxies on this server:"
  echo "  127.0.0.1:1081 .. 127.0.0.1:$((1080 + NUM_PROFILES))"
  echo "Each uses a different WARP IP (different CF locations/endpoints)."
}

main "$@"
