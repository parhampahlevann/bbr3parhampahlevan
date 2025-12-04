#!/usr/bin/env bash
# Cloudflare WARP Menu (Parham Edition)
# Author: Parham Pahlevan
#
# GitHub usage example:
#   bash <(curl -Ls https://raw.githubusercontent.com/USERNAME/REPO/BRANCH/warp-menu.sh)

set -e

# ========== Elevate to root automatically ==========
if [[ $EUID -ne 0 ]]; then
  echo "[*] Re-running this script as root using sudo..."
  exec sudo -E bash "$0" "$@"
fi

# ========== Auto-install path ==========
SCRIPT_PATH="/usr/local/bin/warp-menu"

# Try to resolve current script path (may be a regular file or a pipe/dev/fd)
CURRENT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# Detect if CURRENT_PATH is a regular file (not a pipe/dev/fd)
if [[ "$CURRENT_PATH" != "$SCRIPT_PATH" ]]; then
  if [[ -f "$CURRENT_PATH" ]]; then
    echo "[*] Installing warp-menu to ${SCRIPT_PATH} ..."
    cp "$CURRENT_PATH" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "[✓] Installed warp-menu to ${SCRIPT_PATH}"
    echo "[*] You can later run it with: warp-menu"
  else
    echo "[*] Running from a pipe/FD (e.g. bash <(curl ...)), skipping auto-install."
    echo "[*] If you want persistent install, save this script to a file and run it from there."
  fi
fi

# ========== Colors & Version ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
VERSION="2.4-parham-multiloc-eu"

# ========== Global files ==========
SCAN_RESULT_FILE="/tmp/warp_cf_scan_last.csv"

CONFIG_DIR="/etc/warp-menu"
ENDPOINTS_FILE="${CONFIG_DIR}/endpoints.list"
CURRENT_ENDPOINT_FILE="${CONFIG_DIR}/current_endpoint"

mkdir -p "$CONFIG_DIR"
touch "$ENDPOINTS_FILE" 2>/dev/null || true

# ========== Preload EU Cloudflare endpoints ==========
parham_warp_preload_endpoints() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo "[*] Preloading European Cloudflare endpoints..."
        cat << EOF > "$ENDPOINTS_FILE"
Romania-1|188.114.96.10:2408
Romania-2|188.114.97.10:2408
Germany-1|188.114.98.10:2408
Germany-2|188.114.99.10:2408
Netherlands-1|162.159.192.10:2408
Netherlands-2|162.159.193.10:2408
France-1|162.159.195.10:2408
UK-1|162.159.204.10:2408
EOF
        echo "[✓] Loaded European Cloudflare endpoints."
    fi
}

# ========== Core Checks ==========
parham_warp_is_installed() {
    command -v warp-cli &>/dev/null
}

parham_warp_is_connected() {
    warp-cli status 2>/dev/null | grep -iq "Connected"
}

# ========== Helpers ==========
parham_warp_ensure_proxy_mode() {
    # Ensure WARP is in proxy mode on port 10808
    warp-cli set-mode proxy 2>/dev/null || warp-cli mode proxy
    warp-cli set-proxy-port 10808 2>/dev/null || warp-cli proxy port 10808
}

parham_warp_get_out_ip() {
    # Real outgoing IP (force IPv4) behind WARP proxy
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip=""

    # Try Cloudflare trace first (IPv4 only)
    ip=$(curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '/^ip=/{print $2}')

    # Fallback to IPv4-only services
    if [[ -z "$ip" ]]; then
        ip=$(curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" https://ipv4.icanhazip.com 2>/dev/null | tr -d ' \r\n')
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" https://ifconfig.me 2>/dev/null | tr -d ' \r\n')
    fi

    echo "$ip"
}

parham_warp_get_out_geo() {
    # Get country / country-code via WARP (for checking != TR)
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local geo country country_code

    geo=$(curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" "http://ip-api.com/line/?fields=country,countryCode" 2>/dev/null || true)
    if [[ -z "$geo" ]]; then
        echo ""
        return 1
    fi

    country=$(echo "$geo" | sed -n '1p')
    country_code=$(echo "$geo" | sed -n '2p')

    echo "${country}|${country_code}"
}

parham_warp_set_custom_endpoint() {
    local endpoint="$1"  # e.g. 162.159.192.10:2408
    if [[ -z "$endpoint" ]]; then
        echo -e "${RED}Endpoint is empty.${NC}"
        return 1
    fi
    echo -e "${CYAN}Setting custom endpoint to: ${YELLOW}${endpoint}${NC}"
    warp-cli set-custom-endpoint "$endpoint"
}

parham_warp_clear_custom_endpoint() {
    echo -e "${CYAN}Clearing custom endpoint (back to automatic selection)...${NC}"
    warp-cli clear-custom-endpoint 2>/dev/null || true
}

# ========== Core Functions ==========
parham_warp_install() {
    if parham_warp_is_installed && parham_warp_is_connected; then
        echo -e "${GREEN}WARP is already installed and connected.${NC}"
        read -p "Do you want to reinstall it? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi

    echo -e "${CYAN}Installing WARP-CLI...${NC}"
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "")
    # For Ubuntu 24/25+ fallback to jammy which is supported by Cloudflare repo
    if [[ -z "$codename" || "$codename" == "oracular" || "$codename" == "plucky" ]]; then
        codename="jammy"
    fi

    apt update
    apt install -y curl gpg lsb-release apt-transport-https ca-certificates sudo
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
    apt update
    apt install -y cloudflare-warp

    parham_warp_connect
}

parham_warp_connect() {
    echo -e "${BLUE}Connecting to WARP Proxy...${NC}"
    yes | warp-cli registration new 2>/dev/null || warp-cli register
    parham_warp_ensure_proxy_mode
    warp-cli connect
    sleep 2
}

parham_warp_disconnect() {
    echo -e "${YELLOW}Disconnecting WARP...${NC}"
    warp-cli disconnect 2>/dev/null || true
    sleep 1
}

parham_warp_status() {
    warp-cli status || echo -e "${RED}warp-cli status failed (is it installed?).${NC}"
    echo
    echo -e "${CYAN}External IPv4 via SOCKS5 proxy (if connected):${NC}"
    local ip geo country country_code
    ip=$(parham_warp_get_out_ip)
    if [[ -n "$ip" ]]; then
        echo -e "  IP: ${GREEN}${ip}${NC}"
        geo=$(parham_warp_get_out_geo || true)
        if [[ -n "$geo" ]]; then
            country="${geo%%|*}"
            country_code="${geo##*|}"
            echo -e "  Location: ${CYAN}${country} (${country_code})${NC}"
            if [[ "$country_code" == "TR" ]]; then
                echo -e "  ${YELLOW}Notice:${NC} Current exit location is ${RED}Turkey (TR)${NC}."
                echo -e "  Use scan / multi-location endpoints to switch to another country."
            fi
        fi
    else
        echo -e "  ${RED}Could not retrieve IPv4 (probably not connected or proxy not working).${NC}"
    fi
}

parham_warp_test_proxy() {
    echo -e "${CYAN}Testing SOCKS5 proxy (127.0.0.1:10808)...${NC}"
    local ip
    ip=$(parham_warp_get_out_ip)
    if [[ -n "$ip" ]]; then
        echo -e "[OK] Outgoing IPv4 via WARP: ${GREEN}$ip${NC}"
    else
        echo -e "[FAIL] ${RED}Could not get IPv4 via proxy. Is WARP connected?${NC}"
    fi
}

parham_warp_remove() {
    echo -e "${RED}Removing WARP...${NC}"
    apt remove --purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    apt autoremove -y || true
    echo -e "${GREEN}WARP removed (or was not installed).${NC}"
}

# ========== Change IP (Quick) ==========
parham_warp_quick_change_ip() {
    if ! parham_warp_is_installed; then
        echo -e "${RED}WARP is not installed.${NC}"
        return 1
    fi
    echo -e "${CYAN}Trying quick IP change (disconnect/connect)...${NC}"
    local old_ip new_ip
    old_ip=$(parham_warp_get_out_ip)
    echo -e "Current IPv4: ${YELLOW}${old_ip:-N/A}${NC}"

    for attempt in {1..5}; do
        echo -e "Attempt ${attempt}/5: reconnecting..."
        parham_warp_disconnect
        parham_warp_ensure_proxy_mode
        warp-cli connect
        sleep 2
        new_ip=$(parham_warp_get_out_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "[✓] New IPv4: ${GREEN}$new_ip${NC}"
            return 0
        fi
    done

    echo -e "${YELLOW}IP did not change with quick method. Try the 'New Identity' option.${NC}"
    return 2
}

# ========== Change IP (New Identity) ==========
parham_warp_new_identity() {
    if ! parham_warp_is_installed; then
        echo -e "${RED}WARP is not installed.${NC}"
        return 1
    fi
    echo -e "${CYAN}Issuing a fresh registration (this usually changes the IP)...${NC}"
    local old_ip new_ip
    old_ip=$(parham_warp_get_out_ip)
    echo -e "Old IPv4: ${YELLOW}${old_ip:-N/A}${NC}"

    parham_warp_disconnect

    # Clean previous registration for various versions
    warp-cli registration delete 2>/dev/null || true
    warp-cli deregister 2>/dev/null || true
    warp-cli registration revoke 2>/dev/null || true

    sleep 1
    yes | warp-cli registration new 2>/dev/null || warp-cli register
    parham_warp_ensure_proxy_mode
    warp-cli connect
    sleep 2

    new_ip=$(parham_warp_get_out_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "[✓] New IPv4: ${GREEN}$new_ip${NC}"
        else
            echo -e "${YELLOW}Identity refreshed but IPv4 looks the same. Try again later or from another network.${NC}"
        fi
    else
        echo -e "${RED}Could not obtain new IPv4 after re-registration.${NC}"
        return 2
    fi
}

# ========== FEATURE 1: Scan Cloudflare IPs (Iran-friendly) ==========
parham_warp_scan_cloudflare_ips() {
    echo -e "${CYAN}Scanning Cloudflare IPs to find best endpoints (Iran-friendly)...${NC}"
    echo -e "${YELLOW}Note:${NC} This scan is based on ping from YOUR network. Slower networks will take longer."
    echo
    read -p "Use default range 162.159.192.[0-255]? [Y/n]: " use_default
    local base="162.159.192"
    local start=0
    local end=255
    if [[ "$use_default" =~ ^[Nn]$ ]]; then
        read -p "Base IP (e.g. 162.159.192): " base_input
        [[ -n "$base_input" ]] && base="$base_input"
        read -p "Start host (0-255, default 0): " s
        read -p "End host (0-255, default 255): " e
        [[ -n "$s" ]] && start="$s"
        [[ -n "$e" ]] && end="$e"
    fi

    read -p "Maximum number of good IPs to store? (default 30): " max_ok
    [[ -z "$max_ok" ]] && max_ok=30

    echo -e "${CYAN}Starting scan: ${YELLOW}${base}.${start}-${end}${NC}"
    echo "IP,RTT" > "$SCAN_RESULT_FILE"

    local ok_count=0
    for i in $(seq "$start" "$end"); do
        local ip="${base}.${i}"
        # single ping with 1-second timeout
        local rtt
        rtt=$(ping -c 1 -W 1 "$ip" 2>/dev/null | awk -F'/' 'END{print $5}')
        if [[ -n "$rtt" ]]; then
            echo -e "[OK] ${ip} => ${GREEN}${rtt} ms${NC}"
            echo "${ip},${rtt}" >> "$SCAN_RESULT_FILE"
            ok_count=$((ok_count + 1))
            if [[ "$ok_count" -ge "$max_ok" ]]; then
                echo -e "${GREEN}Reached desired count (${max_ok}). Stopping scan.${NC}"
                break
            fi
        else
            echo -e "[--] ${ip} did not respond."
        fi
    done

    if [[ "$ok_count" -eq 0 ]]; then
        echo -e "${RED}No responsive IPs found in this range. Try another range.${NC}"
        return 1
    fi

    echo
    echo -e "${CYAN}Best results by RTT (lowest first):${NC}"
    sort -t',' -k2 -n "$SCAN_RESULT_FILE" | head -n 10 | column -t -s ','

    echo
    echo -e "${GREEN}Full scan results saved to:${NC} ${YELLOW}${SCAN_RESULT_FILE}${NC}"
    echo -e "${YELLOW}You can now use 'Choose IP from scan & set endpoint' from the main menu.${NC}"
}

# ========== FEATURE 2: Choose scanned IP and set endpoint ==========
parham_warp_select_ip_from_scan() {
    if [[ ! -f "$SCAN_RESULT_FILE" ]]; then
        echo -e "${RED}No scan results found. First run 'Scan Cloudflare IPs' from the menu.${NC}"
        return 1
    fi

    echo -e "${CYAN}Latest scan results (sorted by RTT):${NC}"
    local sorted
    sorted=$(sort -t',' -k2 -n "$SCAN_RESULT_FILE")
    echo "$sorted" | head -n 20 | nl -w2 -s'. ' | sed 's/\t/  /g'
    echo

    read -p "Choose the IP number from the list (0 to cancel): " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input.${NC}"
        return 1
    fi
    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi

    local line
    line=$(echo "$sorted" | sed -n "${idx}p")
    if [[ -z "$line" ]]; then
        echo -e "${RED}Selected number is out of range.${NC}"
        return 1
    fi

    local ip
    ip=$(echo "$line" | cut -d',' -f1)
    read -p "Endpoint port (default 2408, recommended for WARP): " port
    [[ -z "$port" ]] && port=2408

    local endpoint="${ip}:${port}"
    parham_warp_disconnect
    parham_warp_ensure_proxy_mode
    parham_warp_set_custom_endpoint "$endpoint"
    warp-cli connect
    sleep 2

    echo
    parham_warp_status
    echo -e "${GREEN}New endpoint set: ${YELLOW}${endpoint}${NC}"
}

# ========== FEATURE 3: Manual endpoint (custom IP/PORT) ==========
parham_warp_set_endpoint_manual() {
    echo -e "${CYAN}Set custom Cloudflare WARP endpoint (IP:PORT) manually${NC}"
    echo -e "Example: ${YELLOW}162.159.192.10:2408${NC}"
    read -p "Enter endpoint (empty to cancel): " endpoint
    if [[ -z "$endpoint" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi

    read -p "Clear previous custom endpoint before applying this one? [Y/n]: " clear_old
    if [[ ! "$clear_old" =~ ^[Nn]$ ]]; then
        parham_warp_clear_custom_endpoint
    fi

    parham_warp_disconnect
    parham_warp_ensure_proxy_mode
    parham_warp_set_custom_endpoint "$endpoint"
    warp-cli connect
    sleep 2
    parham_warp_status
}

# ========== FEATURE 4: Multi-location endpoints (for outbounds) ==========
parham_warp_list_saved_endpoints() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "${YELLOW}No saved endpoints yet.${NC}"
        return 0
    fi

    local current=""
    [[ -f "$CURRENT_ENDPOINT_FILE" ]] && current=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)

    echo -e "${CYAN}Saved Cloudflare endpoints:${NC}"
    local i=1
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        local mark=""
        if [[ -n "$current" && "$current" == "${name}|${endpoint}" ]]; then
            mark="*"
        fi
        echo " $i)${mark} ${name} -> ${endpoint}"
        i=$((i+1))
    done < "$ENDPOINTS_FILE"
    [[ -n "$current" ]] && echo "  * current endpoint"
}

parham_warp_add_saved_endpoint() {
    echo -e "${CYAN}Add new Cloudflare endpoint (multi-location / outbound).${NC}"
    read -p "Name/label (e.g. US-1, EU, IR-Friendly): " name
    if [[ -z "$name" ]]; then
        echo -e "${RED}Name cannot be empty.${NC}"
        return 1
    fi
    read -p "Endpoint IP:PORT (e.g. 162.159.192.10:2408): " endpoint
    if [[ -z "$endpoint" ]]; then
        echo -e "${RED}Endpoint cannot be empty.${NC}"
        return 1
    fi
    echo "${name}|${endpoint}" >> "$ENDPOINTS_FILE"
    echo -e "${GREEN}Saved endpoint:${NC} ${name} -> ${endpoint}"
    echo "You can now apply it from this menu."
}

parham_warp_apply_saved_endpoint() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "${YELLOW}No saved endpoints to apply.${NC}"
        return 1
    fi
    parham_warp_list_saved_endpoints
    echo
    read -p "Choose endpoint number to apply (0 to cancel): " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input.${NC}"
        return 1
    fi
    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi

    local i=1 name endpoint
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        if [[ "$i" -eq "$idx" ]]; then
            echo -e "${CYAN}Applying endpoint:${NC} ${name} -> ${endpoint}"
            parham_warp_disconnect
            parham_warp_ensure_proxy_mode
            parham_warp_set_custom_endpoint "$endpoint"
            echo "$name|$endpoint" > "$CURRENT_ENDPOINT_FILE"
            warp-cli connect
            sleep 2
            parham_warp_status
            return 0
        fi
        i=$((i+1))
    done < "$ENDPOINTS_FILE"

    echo -e "${RED}Selected number is out of range.${NC}"
    return 1
}

parham_warp_delete_saved_endpoint() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "${YELLOW}No saved endpoints to delete.${NC}"
        return 1
    fi
    parham_warp_list_saved_endpoints
    echo
    read -p "Choose endpoint number to delete (0 to cancel): " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid input.${NC}"
        return 1
    fi
    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi

    local i=1 name endpoint
    local tmp="${ENDPOINTS_FILE}.tmp"
    : > "$tmp"
    local deleted=""
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        if [[ "$i" -eq "$idx" ]]; then
            deleted="${name}|${endpoint}"
        else
            echo "${name}|${endpoint}" >> "$tmp"
        fi
        i=$((i+1))
    done < "$ENDPOINTS_FILE"
    mv "$tmp" "$ENDPOINTS_FILE"

    if [[ -n "$deleted" ]]; then
        echo -e "${GREEN}Deleted:${NC} ${deleted}"
    else
        echo -e "${RED}Nothing deleted (index out of range).${NC}"
    fi
}

parham_warp_rotate_endpoint() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "${YELLOW}No saved endpoints to rotate.${NC}"
        return 1
    fi

    local total=0
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        total=$((total+1))
    done < "$ENDPOINTS_FILE"

    if [[ "$total" -eq 0 ]]; then
        echo -e "${YELLOW}No saved endpoints to rotate.${NC}"
        return 1
    fi

    local current_index=0 current_name="" current_endpoint=""
    if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
        current_name=$(cut -d'|' -f1 "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
        current_endpoint=$(cut -d'|' -f2 "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
        if [[ -n "$current_name" && -n "$current_endpoint" ]]; then
            local i=1 name endpoint
            while IFS='|' read -r name endpoint; do
                [[ -z "$name" ]] && continue
                if [[ "$name" == "$current_name" && "$endpoint" == "$current_endpoint" ]]; then
                    current_index="$i"
                    break
                fi
                i=$((i+1))
            done < "$ENDPOINTS_FILE"
        fi
    fi

    local next_index=$((current_index + 1))
    if [[ "$next_index" -gt "$total" ]]; then
        next_index=1
    fi

    local i=1 name endpoint
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        if [[ "$i" -eq "$next_index" ]]; then
            echo -e "${CYAN}Rotating to endpoint:${NC} ${name} -> ${endpoint}"
            parham_warp_disconnect
            parham_warp_ensure_proxy_mode
            parham_warp_set_custom_endpoint "$endpoint"
            echo "$name|$endpoint" > "$CURRENT_ENDPOINT_FILE"
            warp-cli connect
            sleep 2
            parham_warp_status
            return 0
        fi
        i=$((i+1))
    done < "$ENDPOINTS_FILE"
}

parham_warp_multilocation_menu() {
    while true; do
        clear
        echo -e "${CYAN}Multi-location / Outbound endpoints${NC}"
        echo +-------------------------------------------------------------------+
        parham_warp_list_saved_endpoints
        echo +-------------------------------------------------------------------+
        echo -e "1 - Add new endpoint"
        echo -e "2 - Apply endpoint"
        echo -e "3 - Delete endpoint"
        echo -e "4 - Rotate to next endpoint"
        echo -e "0 - Back to main menu"
        echo +-------------------------------------------------------------------+
        echo -ne "${YELLOW}Select option: ${NC}"
        read -r sub
        case "$sub" in
            1) parham_warp_add_saved_endpoint ;;
            2) parham_warp_apply_saved_endpoint ;;
            3) parham_warp_delete_saved_endpoint ;;
            4) parham_warp_rotate_endpoint ;;
            0) break ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
        echo -e "\nPress Enter to continue..."
        read -r
    done
}

# ========== Menu ==========
parham_warp_draw_menu() {
    clear
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local is_connected="no"
    if parham_warp_is_connected; then
        is_connected="yes"
    fi
    local socks5_ip="N/A"
    [[ "$is_connected" == "yes" ]] && socks5_ip=$(parham_warp_get_out_ip || echo "N/A")

    cat << "EOF"
+-------------------------------------------------------------------+
|   ██╗    ██╗ █████╗ ██████╗ ██████╗        ██████╗██╗     ██╗     |
|   ██║    ██║██╔══██╗██╔══██╗██╔══██╗      ██╔════╝██║     ██║     |
|   ██║ █╗ ██║███████║██████╔╝██████╔╝█████╗██║     ██║     ██║     |
|   ██║███╗██║██╔══██║██╔══██╗██╔═══╝ ╚════╝██║     ██║     ██║     |
|   ╚███╔███╔╝██║  ██║██║  ██║██║           ╚██████╗███████╗██║     |
|    ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝            ╚═════╝╚══════╝╚═╝     |
+-------------------------------------------------------------------+
EOF
    echo -e "| Script by: ${GREEN}Parham Pahlevan${NC} | Version: ${GREEN}${VERSION}${NC}"
    echo +-------------------------------------------------------------------+
    if [[ "$is_connected" == "yes" ]]; then
        echo -e "| WARP Status: ${GREEN}CONNECTED${NC} | Proxy: ${proxy_ip}:${proxy_port} | Out IPv4: ${socks5_ip}"
    else
        echo -e "| WARP Status: ${RED}NOT CONNECTED${NC}"
    fi
    echo +-------------------------------------------------------------------+
    echo -e "| ${YELLOW}Choose an option:${NC}"
    echo +-------------------------------------------------------------------+
    echo -e "| 1 - Install WARP"
    echo -e "| 2 - Show Status"
    echo -e "| 3 - Test Proxy"
    echo -e "| 4 - Remove WARP"
    echo -e "| 5 - Change IP (Quick reconnect)"
    echo -e "| 6 - Change IP (New Identity - stronger)"
    echo -e "| 7 - Scan Cloudflare IPs (Iran friendly)"
    echo -e "| 8 - Choose IP from scan & set endpoint"
    echo -e "| 9 - Set custom endpoint manually (IP:PORT)"
    echo -e "| 10 - Multi-location endpoints (outbounds)"
    echo -e "| 0 - Exit"
    echo +-------------------------------------------------------------------+
    echo -ne "${YELLOW}Select option: ${NC}"
}

parham_warp_main_menu() {
    # Preload EU endpoints if list is empty
    parham_warp_preload_endpoints

    while true; do
        parham_warp_draw_menu
        read -r choice
        case $choice in
            1) parham_warp_install ;;
            2) parham_warp_status ;;
            3) parham_warp_test_proxy ;;
            4) parham_warp_remove ;;
            5) parham_warp_quick_change_ip ;;
            6) parham_warp_new_identity ;;
            7) parham_warp_scan_cloudflare_ips ;;
            8) parham_warp_select_ip_from_scan ;;
            9) parham_warp_set_endpoint_manual ;;
            10) parham_warp_multilocation_menu ;;
            0) echo -e "${GREEN}Exiting...${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid choice. Try again.${NC}" ;;
        esac
        echo -e "\nPress Enter to return to menu..."
        read -r
    done
}

# ========== Run Menu ==========
parham_warp_main_menu
