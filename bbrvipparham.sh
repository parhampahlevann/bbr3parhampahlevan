#!/usr/bin/env bash
# warp-multi-socks.sh - Clean multi WARP + multi SOCKS5 (fixed)
# Based on the logic of the script you pasted (Parsa / Warp-Multi-IP), but rewritten & fixed.

set -euo pipefail

NUM_PROFILES=8                 # how many WARP profiles / proxies
BASE_NET="172.16.0"           # 172.16.0.x internal IPs

WGCF_BIN="/usr/local/bin/wgcf"
CONF_DIR="/etc/wireguard"
WORK_DIR="/root/warp-confs"
DANTED_DIR="/etc/danted-multi"
SYSTEMD_DIR="/etc/systemd/system"

# ---------- colors ----------
red()   { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue()  { echo -e "\033[36m\033[01m$1\033[0m"; }

# ---------- root check ----------
if [[ $EUID -ne 0 ]]; then
  red "This script must be run as root."
  exit 1
fi

clear || true
echo -e "\033[1;33m=========================================="
echo -e "Multi WARP + Multi SOCKS5 (fixed version)"
echo -e "Inspired by Parsa's Warp-Multi-IP"
echo -e "==========================================\033[0m"

# ---------- optional cleanup ----------
read -rp "Do you want to remove ALL existing wgcfX + danted-warpX configs first? (y/n): " CLEAN
CLEAN=${CLEAN,,}
if [[ "$CLEAN" == "y" ]]; then
  blue "Cleaning up old configs, services, and interfaces..."

  # stop any danted-warp services
  for svc in "$SYSTEMD_DIR"/danted-warp*.service; do
    [[ -e "$svc" ]] || continue
    name=$(basename "$svc")
    systemctl stop "$name" 2>/dev/null || true
    systemctl disable "$name" 2>/dev/null || true
    rm -f "$svc"
  done

  rm -rf "$DANTED_DIR"

  # stop wgcfX interfaces
  for i in $(seq 1 32); do
    wg-quick down "wgcf${i}" 2>/dev/null || true
  done

  # delete stray wg interfaces
  for dev in $(ip -o link show | awk -F': ' '{print $2}' | grep '^wg' || true); do
    ip link delete "$dev" 2>/dev/null || true
  done

  # remove wgcf configs
  rm -f "$CONF_DIR"/wgcf*.conf

  # remove working dir
  rm -rf "$WORK_DIR"

  systemctl daemon-reload
  modprobe -r wireguard 2>/dev/null || true

  green "Cleanup done."
fi

# ---------- deps ----------
blue "Installing dependencies (wireguard, resolvconf, curl, jq, dante-server)..."
apt update -y >/dev/null 2>&1
apt install -y wireguard wireguard-tools resolvconf curl jq dante-server unzip >/dev/null 2>&1
green "Base packages installed."

# ---------- wgcf ----------
if ! command -v wgcf >/dev/null 2>&1; then
  blue "Installing wgcf..."
  curl -fsSL git.io/wgcf.sh | bash
  mv wgcf "$WGCF_BIN"
  chmod +x "$WGCF_BIN"
fi
green "wgcf is available."

mkdir -p "$CONF_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ---------- generate WARP profiles ----------
blue "Generating ${NUM_PROFILES} WARP configs (if not present)..."

for i in $(seq 1 "$NUM_PROFILES"); do
  WG_CONF="${CONF_DIR}/wgcf${i}.conf"
  PROFILE_DIR="${WORK_DIR}/warp${i}"

  if [[ -f "$WG_CONF" ]]; then
    yellow "  wgcf${i}.conf already exists, skipping generation."
    continue
  fi

  mkdir -p "$PROFILE_DIR"
  cd "$PROFILE_DIR"

  rm -f wgcf-account.toml wgcf-profile.conf

  blue "  [${i}/${NUM_PROFILES}] wgcf register..."
  wgcf register --accept-tos >/dev/null 2>&1 || {
    red "    wgcf register failed for profile ${i}, skipping."
    cd "$WORK_DIR"
    continue
  }

  wgcf generate >/dev/null 2>&1 || {
    red "    wgcf generate failed for profile ${i}, skipping."
    cd "$WORK_DIR"
    continue
  }

  if [[ ! -f wgcf-profile.conf ]]; then
    red "    wgcf-profile.conf missing for profile ${i}, skipping."
    cd "$WORK_DIR"
    continue
  fi

  cp wgcf-profile.conf "$WG_CONF"
  chmod 600 "$WG_CONF"

  # set unique internal IP and routing table
  ip_suffix=$((i + 1))
  ip_addr="${BASE_NET}.${ip_suffix}"
  table_id=$((51820 + i))

  # replace Address line (drop IPv6, keep only IPv4 /32)
  sed -i -E "s|^Address *=.*|Address = ${ip_addr}/32|" "$WG_CONF"

  # add table + policy rules
  if ! grep -q "^Table *= *" "$WG_CONF"; then
    sed -i "/^\[Interface\]/a Table = ${table_id}\nPostUp = ip rule add from ${ip_addr}/32 table ${table_id}\nPostDown = ip rule del from ${ip_addr}/32 table ${table_id}" "$WG_CONF"
  fi

  green "    Created ${WG_CONF} (IP ${ip_addr}, table ${table_id})."

  cd "$WORK_DIR"
done

# ---------- bring up interfaces (no systemd) ----------
blue "Reloading WireGuard kernel module..."
modprobe -r wireguard 2>/dev/null || true
modprobe wireguard 2>/dev/null || true

blue "Bringing up wgcfX interfaces using wg-quick..."
for i in $(seq 1 "$NUM_PROFILES"); do
  WG_CONF="${CONF_DIR}/wgcf${i}.conf"
  if [[ -f "$WG_CONF" ]]; then
    wg-quick down "wgcf${i}" 2>/dev/null || true
    if wg-quick up "wgcf${i}" >/dev/null 2>&1; then
      green "  wgcf${i} up."
    else
      red "  wgcf${i} failed to start. Check: wg-quick up wgcf${i}"
    fi
  fi
done

# ---------- Dante SOCKS proxies ----------
blue "Setting up Dante SOCKS5 proxies..."
mkdir -p "$DANTED_DIR"

for i in $(seq 1 "$NUM_PROFILES"); do
  WG_CONF="${CONF_DIR}/wgcf${i}.conf"
  if [[ ! -f "$WG_CONF" ]]; then
    yellow "  No wgcf${i}.conf, skip danted-warp${i}."
    continue
  fi

  port=$((1080 + i))
  ip_suffix=$((i + 1))
  internal_ip="${BASE_NET}.${ip_suffix}"

  D_CONF="${DANTED_DIR}/danted-warp${i}.conf"
  SVC="${SYSTEMD_DIR}/danted-warp${i}.service"

  cat >"$D_CONF" <<EOF
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

  cat >"$SVC" <<EOF
[Unit]
Description=Dante SOCKS proxy warp${i}
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/danted -f ${D_CONF}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "danted-warp${i}" >/dev/null 2>&1 || true
  systemctl restart "danted-warp${i}" >/dev/null 2>&1 || true

  green "  danted-warp${i}: SOCKS5 127.0.0.1:${port} (external via ${internal_ip})"
done

# ---------- check proxy IPs ----------
blue "Checking public IPs via each SOCKS5 proxy..."
declare -A ip_map
declare -A proxy_ips

for i in $(seq 1 "$NUM_PROFILES"); do
  port=$((1080 + i))

  # quick restart to be safe
  systemctl restart "danted-warp${i}" 2>/dev/null || true
  wg-quick up "wgcf${i}" 2>/dev/null || true

  sleep 5
  ip_raw=$(curl -s --max-time 15 --socks5 127.0.0.1:${port} https://api.ipify.org || echo "error")
  echo "  wgcf${i} (SOCKS 127.0.0.1:${port}) → ${ip_raw}"
  proxy_ips[$i]="$ip_raw"
  ip_map[$ip_raw]=1
done

echo
green "Setup finished!"
echo "SOCKS5 proxies available:"
for i in $(seq 1 "$NUM_PROFILES"); do
  port=$((1080 + i))
  echo "  wgcf${i} → 127.0.0.1:${port}"
done

echo "If some IPs show 'error', run:"
echo "  systemctl status danted-warp1  (or wg-quick up wgcf1) to see logs."
