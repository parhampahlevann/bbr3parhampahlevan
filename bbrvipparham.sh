#!/usr/bin/env bash
# Cloudflare WARP Menu (Parham Enhanced Edition)
# Author: Parham Pahlevan
# Enhanced with multi-location, IPv6, and bug fixes
# Fixed display issues and installation problems

# ========== Elevate to root automatically ==========
if [[ $EUID -ne 0 ]]; then
  echo "[*] Re-running this script as root using sudo..."
  exec sudo -E bash "$0" "$@"
fi

# ========== Auto-install path ==========
SCRIPT_PATH="/usr/local/bin/warp-menu"

# Try to resolve current script path
CURRENT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# Detect if CURRENT_PATH is a regular file
if [[ "$CURRENT_PATH" != "$SCRIPT_PATH" ]]; then
  if [[ -f "$CURRENT_PATH" ]]; then
    echo "[*] Installing warp-menu to ${SCRIPT_PATH} ..."
    cp -f "$CURRENT_PATH" "$SCRIPT_PATH"
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
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
VERSION="3.2-parham-multiloc-ipv6-fixed"

# ========== Global files ==========
SCAN_RESULT_FILE="/tmp/warp_cf_scan_last.csv"
BEST_ENDPOINTS_FILE="/tmp/warp_best_endpoints.txt"

CONFIG_DIR="/etc/warp-menu"
ENDPOINTS_FILE="${CONFIG_DIR}/endpoints.list"
CURRENT_ENDPOINT_FILE="${CONFIG_DIR}/current_endpoint"
CONNECTION_LOG="${CONFIG_DIR}/connection.log"
WARP_CONFIG_DIR="/var/lib/cloudflare-warp"

mkdir -p "$CONFIG_DIR"
mkdir -p "$WARP_CONFIG_DIR"
touch "$ENDPOINTS_FILE" 2>/dev/null || true
touch "$CONNECTION_LOG" 2>/dev/null || true

# ========== Logging function ==========
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$CONNECTION_LOG"
}

# ========== Preload Cloudflare endpoints ==========
parham_warp_preload_endpoints() {
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo "[*] Preloading Cloudflare endpoints..."
        cat << EOF > "$ENDPOINTS_FILE"
Romania-1|188.114.96.10:2408
Romania-2|188.114.97.10:2408
Germany-1|188.114.98.10:2408
Germany-2|188.114.99.10:2408
Netherlands-1|162.159.192.10:2408
Netherlands-2|162.159.193.10:2408
France-1|162.159.195.10:2408
UK-1|162.159.204.10:2408
USA-1|162.159.208.10:2408
USA-2|162.159.209.10:2408
Switzerland-1|188.114.100.10:2408
Switzerland-2|188.114.101.10:2408
Italy-1|188.114.102.10:2408
Italy-2|188.114.103.10:2408
Spain-1|188.114.104.10:2408
Spain-2|188.114.105.10:2408
Poland-1|188.114.106.10:2408
Poland-2|188.114.107.10:2408
Japan-1|162.159.147.10:2408
Japan-2|162.159.148.10:2408
Singapore-1|162.159.139.10:2408
Singapore-2|162.159.140.10:2408
Australia-1|162.159.151.10:2408
Australia-2|162.159.152.10:2408
Canada-1|162.159.131.10:2408
Canada-2|162.159.132.10:2408
EOF
        echo "[✓] Loaded 26 Cloudflare endpoints from 13 countries."
    fi
}

# ========== Core Checks ==========
parham_warp_is_installed() {
    command -v warp-cli &>/dev/null
}

parham_warp_is_connected() {
    warp-cli --accept-tos status 2>/dev/null | grep -iq "Connected"
}

parham_warp_check_connection() {
    if ! parham_warp_is_installed; then
        echo -e "${RED}WARP is not installed. Please install it first.${NC}"
        return 1
    fi

    if ! parham_warp_is_connected; then
        echo -e "${YELLOW}WARP is not connected. Trying to connect...${NC}"
        parham_warp_connect
        sleep 3
        if ! parham_warp_is_connected; then
            echo -e "${RED}Cannot establish connection. Please check WARP service.${NC}"
            return 1
        fi
    fi
    return 0
}

# ========== Helpers ==========
parham_warp_ensure_proxy_mode() {
    warp-cli --accept-tos set-mode proxy 2>/dev/null || warp-cli --accept-tos mode proxy
    warp-cli --accept-tos set-proxy-port 10808 2>/dev/null || warp-cli --accept-tos proxy port 10808
    sleep 1
}

parham_warp_get_out_ip() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip=""
    local timeout_sec=5

    local services=(
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
        "https://ifconfig.me/ip"
        "https://ipecho.net/plain"
    )

    for service in "${services[@]}"; do
        ip=$(timeout "$timeout_sec" curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" "$service" 2>/dev/null | tr -d ' \r\n')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done

    echo ""
    return 1
}

parham_warp_get_out_ipv6() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip=""
    local timeout_sec=8

    local services=(
        "https://ipv6.icanhazip.com"
        "https://api64.ipify.org"
        "https://ifconfig.co/ip"
        "https://ident.me"
    )

    for service in "${services[@]}"; do
        ip=$(timeout "$timeout_sec" curl -6 -s --socks5 "${proxy_ip}:${proxy_port}" "$service" 2>/dev/null)
        ip=$(echo "$ip" | tr -d ' \r\n')
        if [[ -n "$ip" && "$ip" =~ : ]]; then
            echo "$ip"
            return 0
        fi
    done

    echo ""
    return 1
}

parham_warp_get_out_geo() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local country=""
    local country_code=""
    local isp=""
    local asn=""

    # Try ip-api first
    local raw
    raw=$(timeout 10 curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" \
        "http://ip-api.com/line/?fields=country,countryCode,isp,as" 2>/dev/null || true)

    if [[ -n "$raw" ]]; then
        country=$(echo "$raw" | sed -n '1p')
        country_code=$(echo "$raw" | sed -n '2p')
        isp=$(echo "$raw" | sed -n '3p')
        asn=$(echo "$raw" | sed -n '4p')
    else
        # Fallback to ipinfo if jq is installed
        if command -v jq >/dev/null 2>&1; then
            local json
            json=$(timeout 10 curl -4 -s --socks5 "${proxy_ip}:${proxy_port}" \
                "https://ipinfo.io/json" 2>/dev/null || true)
            if [[ -n "$json" ]]; then
                country=$(echo "$json" | jq -r '.country // ""')
                country_code=$(echo "$json" | jq -r '.country // ""')
                isp=$(echo "$json" | jq -r '.org // ""')
                asn="$isp"
            fi
        fi
    fi

    echo "${country}|${country_code}|${isp}|${asn}"
}

parham_warp_set_custom_endpoint() {
    local endpoint="$1"
    if [[ -z "$endpoint" ]]; then
        echo -e "${RED}Endpoint is empty.${NC}"
        return 1
    fi

    echo -e "${CYAN}Setting custom endpoint to: ${YELLOW}${endpoint}${NC}"
    log_message "Setting endpoint: $endpoint"

    warp-cli --accept-tos clear-custom-endpoint 2>/dev/null || true
    sleep 1
    warp-cli --accept-tos set-custom-endpoint "$endpoint"
    sleep 2
}

parham_warp_clear_custom_endpoint() {
    echo -e "${CYAN}Clearing custom endpoint...${NC}"
    warp-cli --accept-tos clear-custom-endpoint 2>/dev/null || true
    sleep 2
}

parham_warp_restart_warp_service() {
    echo -e "${CYAN}Restarting WARP service...${NC}"
    systemctl restart warp-svc 2>/dev/null || systemctl restart warp-svc.service || true
    sleep 5
}

# ========== Check IPv6 Support ==========
parham_warp_check_ipv6_support() {
    echo -e "${CYAN}Checking IPv6 support...${NC}"
    
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}curl is not installed. Installing...${NC}"
        apt update && apt install -y curl
    fi
    
    echo -e "${YELLOW}Testing IPv6 connectivity...${NC}"
    
    # Test native IPv6
    if timeout 5 curl -6 -s https://ipv6.google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Native IPv6 connectivity is working${NC}"
        NATIVE_IPV6=true
    else
        echo -e "${YELLOW}⚠ Native IPv6 connectivity not available${NC}"
        NATIVE_IPV6=false
    fi
    
    # Test through WARP proxy if connected
    if parham_warp_is_connected; then
        echo -e "${YELLOW}Testing IPv6 through WARP proxy...${NC}"
        local ipv6_out
        ipv6_out=$(parham_warp_get_out_ipv6)
        
        if [[ -n "$ipv6_out" ]]; then
            echo -e "${GREEN}✓ WARP IPv6 is working: ${ipv6_out}${NC}"
            echo -e "${CYAN}Recommendation:${NC}"
            echo -e "  ${GREEN}1.${NC} Use WARP for IPv4 traffic"
            echo -e "  ${GREEN}2.${NC} Use native IPv6 for IPv6 traffic"
            echo -e "  ${GREEN}3.${NC} This gives you dual-stack connectivity"
            return 0
        else
            echo -e "${YELLOW}⚠ WARP IPv6 not available through proxy${NC}"
        fi
    fi
    
    echo -e "${CYAN}IPv6 Configuration Tips:${NC}"
    echo -e "1. Enable IPv6 in your VPS provider panel"
    echo -e "2. Check if your ISP provides IPv6"
    echo -e "3. Use dual-stack setup: WARP for IPv4 + native IPv6"
    return 1
}

# ========== Core Functions ==========
parham_warp_install() {
    echo -e "${CYAN}Installing WARP-CLI...${NC}"
    
    # Check if already installed and connected
    if parham_warp_is_installed && parham_warp_is_connected; then
        echo -e "${GREEN}WARP is already installed and connected.${NC}"
        read -r -p "Do you want to reinstall it? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    # Remove old installation if exists
    if parham_warp_is_installed; then
        echo -e "${YELLOW}Removing old WARP installation...${NC}"
        warp-cli --accept-tos disconnect 2>/dev/null || true
        systemctl stop warp-svc 2>/dev/null || true
        apt remove --purge -y cloudflare-warp 2>/dev/null || true
        rm -rf /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
        rm -rf /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
        sleep 2
    fi
    
    # Detect distribution and codename
    local codename
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        codename="$VERSION_CODENAME"
    else
        codename=$(lsb_release -cs 2>/dev/null || echo "")
    fi
    
    # Map new Ubuntu versions to jammy
    if [[ -z "$codename" ]]; then
        codename="jammy"
    elif [[ "$codename" == "oracular" || "$codename" == "plucky" || "$codename" == "noble" || "$codename" == "xenial" ]]; then
        codename="jammy"
    fi
    
    echo -e "${YELLOW}Detected codename: ${codename}${NC}"
    
    # Update system and install dependencies
    apt update
    apt install -y curl gpg lsb-release apt-transport-https ca-certificates sudo jq bc iputils-ping net-tools dnsutils
    
    # Add Cloudflare WARP repository
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
        | tee /etc/apt/sources.list.d/cloudflare-client.list
    
    # Install WARP
    apt update
    apt install -y cloudflare-warp
    
    # Initialize WARP
    echo -e "${CYAN}Initializing WARP...${NC}"
    
    # Stop service first
    systemctl stop warp-svc 2>/dev/null || true
    sleep 2
    
    # Remove any existing registration
    rm -f "$WARP_CONFIG_DIR/settings.json" 2>/dev/null || true
    rm -f "$WARP_CONFIG_DIR/reg.json" 2>/dev/null || true
    
    # Start service
    systemctl start warp-svc
    sleep 5
    
    # Register
    warp-cli --accept-tos registration new || warp-cli --accept-tos register
    
    # Set proxy mode
    parham_warp_ensure_proxy_mode
    
    # Connect
    warp-cli --accept-tos connect
    sleep 5
    
    # Verify connection
    local attempts=0
    while [[ $attempts -lt 10 ]] && ! parham_warp_is_connected; do
        echo -ne "${YELLOW}Attempting to connect... ${attempts}/10${NC}\r"
        sleep 2
        attempts=$((attempts + 1))
    done
    
    echo
    
    if parham_warp_is_connected; then
        echo -e "${GREEN}✓ WARP installation completed successfully!${NC}"
        
        # Check IPv6 support
        parham_warp_check_ipv6_support
        
        # Show status
        parham_warp_status
    else
        echo -e "${RED}✗ WARP installation completed but failed to connect${NC}"
        echo -e "${YELLOW}Try running: warp-cli --accept-tos connect${NC}"
        return 1
    fi
}

parham_warp_connect() {
    echo -e "${BLUE}Connecting to WARP Proxy...${NC}"

    if ! parham_warp_is_installed; then
        echo -e "${RED}warp-cli is not installed. Run Install first.${NC}"
        return 1
    fi

    # Start service if not running
    if ! systemctl is-active --quiet warp-svc; then
        systemctl start warp-svc
        sleep 3
    fi

    # Check registration
    if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
        echo -e "${YELLOW}No registration found. Creating new one...${NC}"
        warp-cli --accept-tos registration new || warp-cli --accept-tos register
        sleep 2
    fi

    parham_warp_ensure_proxy_mode
    warp-cli --accept-tos connect
    sleep 3

    local attempts=0
    while [[ $attempts -lt 10 ]] && ! parham_warp_is_connected; do
        sleep 1
        attempts=$((attempts + 1))
    done

    if parham_warp_is_connected; then
        echo -e "${GREEN}Connected to WARP${NC}"
        return 0
    else
        echo -e "${RED}Failed to connect to WARP${NC}"
        return 1
    fi
}

parham_warp_disconnect() {
    echo -e "${YELLOW}Disconnecting WARP...${NC}"
    warp-cli --accept-tos disconnect 2>/dev/null || true
    sleep 2
}

parham_warp_status() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                    WARP STATUS                       ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if parham_warp_is_installed; then
        echo -e "\n${BOLD}${GREEN}WARP CLI Status:${NC}"
        warp-cli --accept-tos status 2>/dev/null || echo -e "${RED}warp-cli status failed${NC}"
    else
        echo -e "${RED}✗ warp-cli is not installed${NC}"
        return 1
    fi
    
    echo -e "\n${CYAN}──────────────────────────────────────────────────────────────${NC}"
    
    if parham_warp_is_connected; then
        echo -e "${BOLD}${GREEN}Connection Details:${NC}"
        
        # Get IPv4
        local ip4
        ip4=$(parham_warp_get_out_ip 2>/dev/null || echo "")
        if [[ -n "$ip4" ]]; then
            echo -e "  ${GREEN}• IPv4 (WARP Out):${NC} $ip4"
        else
            echo -e "  ${RED}• IPv4 (WARP Out):${NC} Not available"
        fi
        
        # Get IPv6
        local ip6
        ip6=$(parham_warp_get_out_ipv6 2>/dev/null || echo "")
        if [[ -n "$ip6" ]]; then
            echo -e "  ${GREEN}• IPv6 (Cloudflare):${NC} $ip6"
        else
            echo -e "  ${YELLOW}• IPv6 (Cloudflare):${NC} Not detected"
        fi
        
        # Get geo location
        local geo
        geo=$(parham_warp_get_out_geo 2>/dev/null || echo "")
        if [[ -n "$geo" ]]; then
            IFS='|' read -r country country_code isp asn <<< "$geo"
            echo -e "  ${GREEN}• Location:${NC} $country (${country_code})"
            [[ -n "$isp" ]] && echo -e "  ${GREEN}• ISP:${NC} $isp"
            [[ -n "$asn" ]] && echo -e "  ${GREEN}• ASN:${NC} $asn"
            
            # Warning for Turkey
            if [[ "$country_code" == "TR" ]]; then
                echo -e "\n  ${RED}⚠ Warning:${NC} Current exit location is ${RED}Turkey (TR)${NC}"
                echo -e "    Use multi-location endpoints to switch to another country."
            fi
        fi
        
        # Get endpoint info
        local endpoint_info
        endpoint_info=$(warp-cli --accept-tos settings 2>/dev/null | grep -i "endpoint" || true)
        if [[ -n "$endpoint_info" ]]; then
            local current_endpoint
            current_endpoint=$(echo "$endpoint_info" | grep -o '[0-9.:]\+' | head -1)
            echo -e "  ${GREEN}• Endpoint:${NC} $current_endpoint"
            
            # Show endpoint name if saved
            if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
                local saved_name
                saved_name=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null | cut -d'|' -f1 || true)
                if [[ -n "$saved_name" ]]; then
                    echo -e "  ${GREEN}• Endpoint Name:${NC} $saved_name"
                fi
            fi
        fi
        
        echo -e "\n${CYAN}──────────────────────────────────────────────────────────────${NC}"
        echo -e "${BOLD}${GREEN}Proxy Tests:${NC}"
        
        # Test IPv4 proxy
        echo -ne "  ${CYAN}• Testing IPv4 proxy...${NC} "
        if timeout 5 curl -4 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Working${NC}"
        else
            echo -e "${RED}✗ Failed${NC}"
        fi
        
        # Test IPv6 proxy
        echo -ne "  ${CYAN}• Testing IPv6 proxy...${NC} "
        if timeout 8 curl -6 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Working${NC}"
        else
            echo -e "${YELLOW}⚠ Not available${NC}"
        fi
        
        # Test DNS
        echo -ne "  ${CYAN}• Testing DNS...${NC} "
        if timeout 5 dig @1.1.1.1 cloudflare.com +short > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Working${NC}"
        else
            echo -e "${YELLOW}⚠ Check DNS settings${NC}"
        fi
        
    else
        echo -e "${RED}✗ WARP is not connected${NC}"
    fi
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

parham_warp_test_proxy() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                    PROXY TESTS                       ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if ! parham_warp_check_connection; then
        echo -e "\n${RED}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    echo -e "\n${BOLD}${GREEN}Testing SOCKS5 proxy (127.0.0.1:10808)...${NC}\n"
    
    local services=(
        "Cloudflare:https://www.cloudflare.com"
        "Google:https://www.google.com"
        "Github:https://github.com"
        "Wikipedia:https://www.wikipedia.org"
        "IP Check (IPv4):https://api.ipify.org"
        "IP Check (IPv6):https://api64.ipify.org"
    )
    
    for service in "${services[@]}"; do
        local name="${service%%:*}"
        local url="${service#*:}"
        
        echo -ne "  ${CYAN}• ${name}...${NC} "
        
        # Determine if it's IPv6 test
        if [[ "$name" == *"IPv6"* ]]; then
            if timeout 8 curl -6 -s --socks5 127.0.0.1:10808 "$url" > /dev/null 2>&1; then
                echo -e "${GREEN}✓ OK${NC}"
            else
                echo -e "${YELLOW}⚠ Not available${NC}"
            fi
        else
            if timeout 5 curl -4 -s --socks5 127.0.0.1:10808 "$url" > /dev/null 2>&1; then
                echo -e "${GREEN}✓ OK${NC}"
            else
                echo -e "${RED}✗ FAIL${NC}"
            fi
        fi
    done
    
    echo -e "\n${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}${GREEN}Current IP Addresses:${NC}\n"
    
    local ip4 ip6
    ip4=$(parham_warp_get_out_ip)
    ip6=$(parham_warp_get_out_ipv6)
    
    if [[ -n "$ip4" ]]; then
        echo -e "  ${GREEN}• IPv4 (WARP Out):${NC} $ip4"
    else
        echo -e "  ${RED}• IPv4:${NC} Could not get IPv4"
    fi
    
    if [[ -n "$ip6" ]]; then
        echo -e "  ${GREEN}• IPv6 (Cloudflare):${NC} $ip6"
    else
        echo -e "  ${YELLOW}• IPv6:${NC} No IPv6 address detected"
        
        # Offer IPv6 test
        echo -e "\n${CYAN}Want to test IPv6 support?${NC}"
        read -r -p "Test IPv6 connectivity? [y/N]: " ipv6_test
        if [[ "$ipv6_test" =~ ^[Yy]$ ]]; then
            parham_warp_check_ipv6_support
        fi
    fi
    
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

parham_warp_remove() {
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${RED}                    REMOVE WARP                       ${NC}"
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}⚠ WARNING: This will completely remove WARP from your system.${NC}\n"
    
    read -r -p "Are you sure you want to continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Cancelled.${NC}"
        return 0
    fi
    
    echo -e "\n${RED}Removing WARP...${NC}"
    
    # Disconnect first
    warp-cli --accept-tos disconnect 2>/dev/null || true
    sleep 2
    
    # Stop service
    systemctl stop warp-svc 2>/dev/null || true
    
    # Remove package
    apt remove --purge -y cloudflare-warp 2>/dev/null || true
    
    # Remove repository
    rm -f /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
    
    # Remove config files
    rm -rf "$WARP_CONFIG_DIR" 2>/dev/null || true
    rm -rf /etc/cloudflare-warp/ 2>/dev/null || true
    
    # Clean up
    apt autoremove -y 2>/dev/null || true
    apt clean 2>/dev/null || true
    
    echo -e "\n${GREEN}✓ WARP removed successfully${NC}"
    echo -e "${YELLOW}Note: Configuration files in ${CONFIG_DIR} were kept.${NC}"
}

# ========== Change IP Functions ==========
parham_warp_quick_change_ip() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                QUICK IP CHANGE                      ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if ! parham_warp_check_connection; then
        echo -e "\n${RED}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    echo -e "\n${GREEN}Quick IP change (reconnect)...${NC}"
    local old_ip new_ip
    
    old_ip=$(parham_warp_get_out_ip)
    echo -e "Current IP: ${YELLOW}${old_ip:-N/A}${NC}"
    
    for attempt in {1..3}; do
        echo -e "\n${CYAN}Attempt ${attempt}/3:${NC}"
        parham_warp_disconnect
        sleep 2
        parham_warp_connect
        sleep 3
        
        new_ip=$(parham_warp_get_out_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}✓ New IP: $new_ip${NC}"
            echo -e "\n${GREEN}IP changed successfully!${NC}"
            
            # Test new IP
            echo -ne "\n${CYAN}Testing new connection...${NC} "
            if timeout 5 curl -4 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
                echo -e "${GREEN}✓ Working${NC}"
            else
                echo -e "${YELLOW}⚠ Test failed${NC}"
            fi
            
            return 0
        else
            echo -e "${YELLOW}IP remained the same${NC}"
        fi
    done
    
    echo -e "\n${YELLOW}⚠ IP did not change. Try 'New Identity' option.${NC}"
    return 1
}

parham_warp_new_identity() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                 NEW IDENTITY                        ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if ! parham_warp_check_connection; then
        echo -e "\n${RED}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    echo -e "\n${RED}⚠ This will reset your WARP connection completely.${NC}\n"
    
    read -r -p "Are you sure? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Cancelled.${NC}"
        return 0
    fi
    
    echo -e "\n${CYAN}New Identity (full reset)...${NC}"
    local old_ip new_ip
    
    old_ip=$(parham_warp_get_out_ip)
    echo -e "Old IP: ${YELLOW}${old_ip:-N/A}${NC}"
    
    parham_warp_disconnect
    
    warp-cli --accept-tos registration delete 2>/dev/null || true
    warp-cli --accept-tos clear-custom-endpoint 2>/dev/null || true
    sleep 2
    
    parham_warp_restart_warp_service
    
    warp-cli --accept-tos registration new || warp-cli --accept-tos register
    parham_warp_ensure_proxy_mode
    warp-cli --accept-tos connect
    sleep 5
    
    new_ip=$(parham_warp_get_out_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}✓ New Identity IP: $new_ip${NC}"
        else
            echo -e "${YELLOW}⚠ IP remained the same: $new_ip${NC}"
        fi
    else
        echo -e "${RED}✗ Failed to get new IP${NC}"
        return 1
    fi
}

# ========== Scanning Functions ==========
parham_warp_scan_cloudflare_ips() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}              SCAN CLOUDFLARE IPs                    ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Note: This may take a few minutes${NC}\n"
    
    read -r -p "Use default range 162.159.192.[0-255]? [Y/n]: " use_default
    local base="162.159.192"
    local start=0
    local end=255
    
    if [[ "$use_default" =~ ^[Nn]$ ]]; then
        read -r -p "Base IP (e.g. 162.159.192): " base_input
        [[ -n "$base_input" ]] && base="$base_input"
        read -r -p "Start host (0-255): " s
        read -r -p "End host (0-255): " e
        [[ -n "$s" ]] && start="$s"
        [[ -n "$e" ]] && end="$e"
    fi
    
    read -r -p "Max IPs to find (default 20): " max_ok
    [[ -z "$max_ok" ]] && max_ok=20
    
    echo -e "\n${CYAN}Scanning ${base}.${start}-${end} ...${NC}"
    echo "IP,RTT(ms)" > "$SCAN_RESULT_FILE"
    
    local ok_count=0
    local total=$((end - start + 1))
    local current=0
    
    echo -e "\n${YELLOW}Starting scan...${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    
    for i in $(seq "$start" "$end"); do
        current=$((current + 1))
        local ip="${base}.${i}"
        local progress=$((current * 100 / total))
        
        echo -ne "\r${CYAN}Progress: ${progress}% (${current}/${total}) - Found: ${ok_count} IPs${NC}"
        
        local rtt
        rtt=$(ping -c 2 -W 1 "$ip" 2>/dev/null | awk -F'/' 'END{print $5}')
        
        if [[ -n "$rtt" ]]; then
            echo "$ip,$rtt" >> "$SCAN_RESULT_FILE"
            ok_count=$((ok_count + 1))
            
            if [[ "$ok_count" -ge "$max_ok" ]]; then
                echo -e "\n${GREEN}✓ Found ${max_ok} IPs, stopping scan.${NC}"
                break
            fi
        fi
    done
    
    echo -e "\n${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "\n${GREEN}Scan completed. Found ${ok_count} responsive IPs.${NC}"
    
    if [[ "$ok_count" -gt 0 ]]; then
        echo -e "\n${BOLD}${GREEN}Top 10 fastest IPs:${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
        sort -t',' -k2 -n "$SCAN_RESULT_FILE" | head -10 | column -t -s ','
        
        echo -e "\n${CYAN}Saving best endpoints...${NC}"
        : > "$BEST_ENDPOINTS_FILE"
        sort -t',' -k2 -n "$SCAN_RESULT_FILE" | head -5 | while IFS=',' read -r ip rtt; do
            echo "${ip}:2408|${rtt}ms" >> "$BEST_ENDPOINTS_FILE"
        done
        
        echo -e "${GREEN}✓ Best endpoints saved to:${NC} $BEST_ENDPOINTS_FILE"
    else
        echo -e "${RED}✗ No responsive IPs found.${NC}"
    fi
}

parham_warp_select_ip_from_scan() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}           SELECT SCANNED IP                         ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if [[ ! -f "$SCAN_RESULT_FILE" ]]; then
        echo -e "\n${RED}✗ No scan results. Run scan first.${NC}"
        echo -e "\n${RED}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    echo -e "\n${GREEN}Select IP from scan results:${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}No.  IP              RTT(ms)${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    
    local sorted
    sorted=$(sort -t',' -k2 -n "$SCAN_RESULT_FILE")
    local count=0
    
    while IFS=',' read -r ip rtt; do
        count=$((count + 1))
        printf " %2d. %-15s %6s\n" "$count" "$ip" "$rtt"
        [[ $count -eq 20 ]] && break
    done <<< "$sorted"
    
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "\n${CYAN}Select IP (1-${count}, 0 to cancel):${NC} "
    read -r idx
    
    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi
    
    if [[ "$idx" -gt 0 && "$idx" -le "$count" ]]; then
        local selected
        selected=$(echo "$sorted" | sed -n "${idx}p")
        local ip="${selected%%,*}"
        
        echo -e "\n${GREEN}Selected IP: ${YELLOW}$ip${NC}"
        read -r -p "Port (default 2408): " port
        [[ -z "$port" ]] && port=2408
        
        local endpoint="${ip}:${port}"
        
        echo -e "\n${CYAN}Applying endpoint...${NC}"
        parham_warp_disconnect
        parham_warp_set_custom_endpoint "$endpoint"
        warp-cli --accept-tos connect
        sleep 5
        
        echo -e "\n${GREEN}✓ Endpoint applied successfully!${NC}"
        parham_warp_status
    else
        echo -e "${RED}✗ Invalid selection.${NC}"
    fi
}

parham_warp_test_endpoint_speed() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}           ENDPOINT SPEED TEST                       ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if ! parham_warp_check_connection; then
        echo -e "\n${RED}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    echo -e "\n${GREEN}Testing endpoint speed...${NC}"
    
    local endpoint_info
    endpoint_info=$(warp-cli --accept-tos settings 2>/dev/null | grep -i "endpoint" || true)
    local endpoint=""
    
    if [[ -n "$endpoint_info" ]]; then
        endpoint=$(echo "$endpoint_info" | grep -o '[0-9.:]\+' | head -1)
        echo -e "Current endpoint: ${YELLOW}$endpoint${NC}"
    fi
    
    echo -e "\n${CYAN}Running speed test via proxy...${NC}"
    
    # Download test
    echo -ne "  ${CYAN}• Download speed test...${NC} "
    local start_time download_time speed_mbps
    
    start_time=$(date +%s.%N)
    if curl -4 -s --socks5 127.0.0.1:10808 http://speedtest.ftp.otenet.gr/files/test100k.db > /dev/null 2>&1; then
        download_time=$(echo "$(date +%s.%N) - $start_time" | bc)
        if (( $(echo "$download_time > 0" | bc -l) )); then
            speed_mbps=$(echo "scale=2; 0.8 / $download_time" | bc)
            echo -e "${GREEN}${speed_mbps} Mbps${NC}"
        else
            echo -e "${YELLOW}Too fast to measure${NC}"
        fi
    else
        echo -e "${RED}Failed${NC}"
    fi
    
    # Latency test
    echo -ne "  ${CYAN}• Latency to Cloudflare...${NC} "
    local latency
    latency=$(curl -4 -s --socks5 127.0.0.1:10808 -w "%{time_connect}\n" -o /dev/null https://www.cloudflare.com 2>/dev/null || echo "0")
    if [[ "$latency" != "0" ]]; then
        local latency_ms
        latency_ms=$(echo "$latency * 1000" | bc | cut -d. -f1)
        echo -e "${GREEN}${latency_ms} ms${NC}"
    else
        echo -e "${RED}Failed${NC}"
    fi
    
    # IPv6 speed test if available
    local ipv6_ip
    ipv6_ip=$(parham_warp_get_out_ipv6)
    if [[ -n "$ipv6_ip" ]]; then
        echo -ne "  ${CYAN}• IPv6 connectivity test...${NC} "
        if timeout 5 curl -6 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Working${NC}"
        else
            echo -e "${YELLOW}⚠ Slow or unstable${NC}"
        fi
    fi
    
    echo -e "\n${GREEN}Speed test completed.${NC}"
}

# ========== Multi-location Functions ==========
parham_warp_list_saved_endpoints() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}           SAVED ENDPOINTS                          ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "\n${YELLOW}No saved endpoints.${NC}"
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
        return 0
    fi
    
    local current_endpoint=""
    [[ -f "$CURRENT_ENDPOINT_FILE" ]] && current_endpoint=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
    
    echo -e "\n${GREEN}Saved endpoints:${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}#  Name                 Endpoint                 Status${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    
    local i=1
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        
        local mark=" "
        if [[ "${name}|${endpoint}" == "$current_endpoint" ]]; then
            mark="${GREEN}✓${NC}"
        fi
        
        printf " %2d. %-20s %-25s %s\n" "$i" "$name" "$endpoint" "$mark"
        i=$((i + 1))
    done < "$ENDPOINTS_FILE"
    
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    [[ -n "$current_endpoint" ]] && echo -e "\n${GREEN}✓ Currently active endpoint${NC}"
}

parham_warp_add_saved_endpoint() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}           ADD NEW ENDPOINT                         ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Example: Germany-Frankfurt-1|188.114.98.10:2408${NC}\n"
    
    read -r -p "Name/Label: " name
    [[ -z "$name" ]] && {
        echo -e "${RED}✗ Name is required.${NC}"
        sleep 2
        return 1
    }
    
    read -r -p "Endpoint (IP:PORT): " endpoint
    [[ -z "$endpoint" ]] && {
        echo -e "${RED}✗ Endpoint is required.${NC}"
        sleep 2
        return 1
    }
    
    if ! [[ "$endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
        echo -e "${RED}✗ Invalid endpoint format. Use IP:PORT${NC}"
        sleep 2
        return 1
    fi
    
    echo "${name}|${endpoint}" >> "$ENDPOINTS_FILE"
    echo -e "\n${GREEN}✓ Endpoint added: ${name} → ${endpoint}${NC}"
    sleep 2
}

parham_warp_apply_saved_endpoint() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}           APPLY ENDPOINT                           ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "\n${YELLOW}No saved endpoints.${NC}"
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    parham_warp_list_saved_endpoints
    
    local count
    count=$(grep -c '|' "$ENDPOINTS_FILE")
    
    echo -e "\n${CYAN}Select endpoint (1-${count}, 0 to cancel):${NC} "
    read -r idx
    
    if [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        return 0
    fi
    
    if [[ "$idx" -gt 0 && "$idx" -le "$count" ]]; then
        local selected
        selected=$(sed -n "${idx}p" "$ENDPOINTS_FILE")
        local name="${selected%%|*}"
        local endpoint="${selected#*|}"
        
        echo -e "\n${GREEN}Applying endpoint: ${YELLOW}${name}${NC}"
        echo -e "Endpoint: ${CYAN}${endpoint}${NC}"
        
        log_message "Applying endpoint: $name -> $endpoint"
        
        parham_warp_disconnect
        parham_warp_set_custom_endpoint "$endpoint"
        
        echo "$name|$endpoint" > "$CURRENT_ENDPOINT_FILE"
        
        warp-cli --accept-tos connect
        sleep 5
        
        if parham_warp_is_connected; then
            echo -e "\n${GREEN}✓ Successfully applied endpoint!${NC}"
            
            local new_ip
            new_ip=$(parham_warp_get_out_ip)
            if [[ -n "$new_ip" ]]; then
                echo -e "${GREEN}New IP: ${new_ip}${NC}"
                
                local geo
                geo=$(parham_warp_get_out_geo 2>/dev/null || true)
                if [[ -n "$geo" ]]; then
                    IFS='|' read -r country country_code isp asn <<< "$geo"
                    echo -e "${CYAN}Location: ${country} (${country_code})${NC}"
                fi
            fi
            
            # Test IPv6
            local ipv6_ip
            ipv6_ip=$(parham_warp_get_out_ipv6)
            if [[ -n "$ipv6_ip" ]]; then
                echo -e "${GREEN}IPv6: ${ipv6_ip}${NC}"
            fi
        else
            echo -e "\n${RED}✗ Failed to connect with new endpoint${NC}"
        fi
    else
        echo -e "\n${RED}✗ Invalid selection.${NC}"
    fi
}

parham_warp_rotate_endpoint() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}           ROTATE ENDPOINT                          ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    if [[ ! -s "$ENDPOINTS_FILE" ]]; then
        echo -e "\n${YELLOW}No saved endpoints.${NC}"
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    local current=""
    if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
        current=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
    fi
    
    local current_idx=0 idx=1
    while IFS='|' read -r name endpoint; do
        [[ -z "$name" ]] && continue
        if [[ "$current" == "${name}|${endpoint}" ]]; then
            current_idx=$idx
            break
        fi
        idx=$((idx + 1))
    done < "$ENDPOINTS_FILE"
    
    local total
    total=$(grep -c '|' "$ENDPOINTS_FILE")
    
    local next_idx=$((current_idx % total + 1))
    
    local next_endpoint
    next_endpoint=$(sed -n "${next_idx}p" "$ENDPOINTS_FILE")
    local next_name="${next_endpoint%%|*}"
    local next_addr="${next_endpoint#*|}"
    
    echo -e "\n${GREEN}Rotating endpoint...${NC}"
    echo -e "Current: ${YELLOW}$(echo "$current" | cut -d'|' -f1)${NC}"
    echo -e "Next: ${CYAN}${next_name}${NC}"
    
    parham_warp_disconnect
    parham_warp_set_custom_endpoint "$next_addr"
    echo "$next_name|$next_addr" > "$CURRENT_ENDPOINT_FILE"
    warp-cli --accept-tos connect
    sleep 5
    
    if parham_warp_is_connected; then
        echo -e "\n${GREEN}✓ Rotated to: ${next_name}${NC}"
        local new_ip
        new_ip=$(parham_warp_get_out_ip)
        [[ -n "$new_ip" ]] && echo -e "${GREEN}New IP: ${new_ip}${NC}"
        
        local ipv6_ip
        ipv6_ip=$(parham_warp_get_out_ipv6)
        [[ -n "$ipv6_ip" ]] && echo -e "${GREEN}IPv6: ${ipv6_ip}${NC}"
    else
        echo -e "\n${RED}✗ Rotation failed${NC}"
    fi
}

parham_warp_multilocation_menu() {
    while true; do
        clear
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}           MULTI-LOCATION MANAGER                  ${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}        Manage your WARP endpoints for different locations${NC}\n"
        
        # Show current status
        if parham_warp_is_connected; then
            local current_ip
            current_ip=$(parham_warp_get_out_ip 2>/dev/null || echo "N/A")
            local current_endpoint=""
            [[ -f "$CURRENT_ENDPOINT_FILE" ]] && current_endpoint=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null | cut -d'|' -f1 || true)
            
            echo -e "${GREEN}Current Status:${NC}"
            echo -e "  ${CYAN}• IP:${NC} ${current_ip}"
            echo -e "  ${CYAN}• Endpoint:${NC} ${current_endpoint:-Auto}"
            echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}\n"
        fi
        
        echo -e "${BOLD}${GREEN}Options:${NC}"
        echo -e " ${GREEN}1${NC}) List all endpoints"
        echo -e " ${GREEN}2${NC}) Add new endpoint"
        echo -e " ${GREEN}3${NC}) Apply endpoint"
        echo -e " ${GREEN}4${NC}) Rotate to next endpoint"
        echo -e " ${GREEN}5${NC}) Test current endpoint speed"
        echo -e " ${GREEN}6${NC}) Delete endpoint"
        echo -e " ${GREEN}7${NC}) Check IPv6 support"
        echo -e " ${RED}0${NC}) Back to main menu"
        echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
        
        read -r -p "${YELLOW}Select option: ${NC}" choice
        
        case $choice in
            1) parham_warp_list_saved_endpoints ;;
            2) parham_warp_add_saved_endpoint ;;
            3) parham_warp_apply_saved_endpoint ;;
            4) parham_warp_rotate_endpoint ;;
            5) parham_warp_test_endpoint_speed ;;
            6)
                echo -e "${YELLOW}Deleting endpoints...${NC}"
                echo -e "Edit this file manually if needed: $ENDPOINTS_FILE"
                sleep 2
                ;;
            7) parham_warp_check_ipv6_support ;;
            0) break ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
        
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
    done
}

# ========== Traffic Routing Tips ==========
parham_warp_traffic_tips() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}           TRAFFIC ROUTING TIPS                      ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}Optimizing WARP + IPv6 Traffic:${NC}\n"
    
    echo -e "${BOLD}${YELLOW}Scenario 1: Dual-Stack Setup (Recommended)${NC}"
    echo -e "  ${GREEN}•${NC} Use WARP for IPv4 traffic"
    echo -e "  ${GREEN}•${NC} Use native IPv6 for IPv6 traffic"
    echo -e "  ${GREEN}•${NC} Benefits:"
    echo -e "     - IPv4 through Cloudflare's secure network"
    echo -e "     - IPv6 direct for better performance"
    echo -e "     - Bypass IPv4 restrictions while keeping IPv6 speed"
    
    echo -e "\n${BOLD}${YELLOW}Scenario 2: Full WARP Tunnel${NC}"
    echo -e "  ${GREEN}•${NC} All traffic (IPv4+IPv6) through WARP"
    echo -e "  ${GREEN}•${NC} Use when:"
    echo -e "     - You need maximum privacy"
    echo -e "     - Your IPv6 is blocked or slow"
    echo -e "     - You want consistent Cloudflare IPs"
    
    echo -e "\n${BOLD}${YELLOW}Scenario 3: Split Routing${NC}"
    echo -e "  ${GREEN}•${NC} WARP for specific apps (browser, torrent)"
    echo -e "  ${GREEN}•${NC} Direct for others (SSH, games)"
    echo -e "  ${GREEN}•${NC} Use iptables or routing rules"
    
    echo -e "\n${BOLD}${YELLOW}Tips for Bypassing Traffic:${NC}"
    echo -e "  ${GREEN}1.${NC} Use multi-location endpoints to avoid Turkey (TR) IPs"
    echo -e "  ${GREEN}2.${NC} Regularly rotate endpoints to prevent blocking"
    echo -e "  ${GREEN}3.${NC} Test IPv6 support: ${CYAN}warp-menu --test-ipv6${NC}"
    echo -e "  ${GREEN}4.${NC} Monitor connection: ${CYAN}warp-menu --status${NC}"
    
    echo -e "\n${BOLD}${YELLOW}Common Endpoints for Different Regions:${NC}"
    echo -e "  ${CYAN}• Europe:${NC} Germany, Netherlands, France"
    echo -e "  ${CYAN}• Americas:${NC} USA, Canada"
    echo -e "  ${CYAN}• Asia:${NC} Japan, Singapore"
    echo -e "  ${CYAN}• Avoid:${NC} Turkey (TR) if you need unrestricted access"
    
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

# ========== Main Menu ==========
parham_warp_draw_menu() {
    clear
    
    # Get current status
    local status_color status_text
    local current_ip="N/A"
    local location=""
    local ipv6_status=""
    
    if parham_warp_is_connected; then
        status_color="$GREEN"
        status_text="CONNECTED"
        current_ip=$(parham_warp_get_out_ip 2>/dev/null || echo "N/A")
        
        # Get IPv6 status
        local ipv6_ip
        ipv6_ip=$(parham_warp_get_out_ipv6 2>/dev/null || echo "")
        if [[ -n "$ipv6_ip" ]]; then
            ipv6_status="${GREEN}✓ IPv6 Available${NC}"
        else
            ipv6_status="${YELLOW}⚠ IPv6 Not Detected${NC}"
        fi
        
        # Get location
        local geo
        geo=$(parham_warp_get_out_geo 2>/dev/null || true)
        if [[ -n "$geo" ]]; then
            IFS='|' read -r country _ _ _ <<< "$geo"
            location="$country"
        fi
    else
        status_color="$RED"
        status_text="DISCONNECTED"
        ipv6_status="${YELLOW}─ Not Connected ─${NC}"
    fi
    
    # Get current endpoint
    local endpoint_info="Auto"
    if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
        local current
        current=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
        if [[ -n "$current" ]]; then
            endpoint_info=$(echo "$current" | cut -d'|' -f1)
        fi
    fi
    
    # Draw menu
    cat << EOF
${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}
${CYAN}║       ${BOLD}WARP MANAGER v${VERSION} - Enhanced Edition${NC}         ${CYAN}║${NC}
${CYAN}║               ${BOLD}by Parham Pahlevan${NC}                        ${CYAN}║${NC}
${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}

${GREEN}┌─ Status ───────────────────────────────────────────────────┐${NC}
${GREEN}│${NC}  Connection: ${status_color}${status_text}${NC}
${GREEN}│${NC}  Current IP: ${YELLOW}${current_ip}${NC}
${GREEN}│${NC}  Location:   ${CYAN}${location:-Unknown}${NC}
${GREEN}│${NC}  Endpoint:   ${PURPLE}${endpoint_info}${NC}
${GREEN}│${NC}  IPv6:       ${ipv6_status}
${GREEN}└────────────────────────────────────────────────────────────┘${NC}

${BOLD}${GREEN}Main Options:${NC}
 ${GREEN}[1]${NC} Install WARP
 ${GREEN}[2]${NC} Status & Information
 ${GREEN}[3]${NC} Test Proxy Connection
 ${GREEN}[4]${NC} Remove WARP

${BOLD}${CYAN}Connection Management:${NC}
 ${CYAN}[5]${NC} Quick IP Change
 ${CYAN}[6]${NC} New Identity (Full Reset)
 ${CYAN}[7]${NC} Connect
 ${CYAN}[8]${NC} Disconnect

${BOLD}${YELLOW}Advanced Features:${NC}
 ${YELLOW}[9]${NC} Scan Cloudflare IPs
 ${YELLOW}[10]${NC} Apply Scanned IP
 ${YELLOW}[11]${NC} Multi-location Manager
 ${YELLOW}[12]${NC} Manual Endpoint Setup

${BOLD}${PURPLE}Tools & Information:${NC}
 ${PURPLE}[13]${NC} Traffic Routing Tips
 ${PURPLE}[14]${NC} Test IPv6 Support
 ${PURPLE}[15]${NC} View Connection Log

${RED}[0]${NC} Exit

${CYAN}──────────────────────────────────────────────────────────────${NC}
EOF
}

parham_warp_main_menu() {
    parham_warp_preload_endpoints
    
    while true; do
        parham_warp_draw_menu
        echo -ne "${YELLOW}Select option [0-15]: ${NC}"
        read -r choice
        
        case $choice in
            1) parham_warp_install ;;
            2) parham_warp_status ;;
            3) parham_warp_test_proxy ;;
            4) parham_warp_remove ;;
            5) parham_warp_quick_change_ip ;;
            6) parham_warp_new_identity ;;
            7) parham_warp_connect ;;
            8) parham_warp_disconnect ;;
            9) parham_warp_scan_cloudflare_ips ;;
            10) parham_warp_select_ip_from_scan ;;
            11) parham_warp_multilocation_menu ;;
            12)
                echo -e "${CYAN}Manual endpoint setup${NC}"
                read -r -p "Enter IP:PORT (e.g. 162.159.192.10:2408): " manual_endpoint
                if [[ -n "$manual_endpoint" ]]; then
                    parham_warp_disconnect
                    parham_warp_set_custom_endpoint "$manual_endpoint"
                    echo "Manual|$manual_endpoint" > "$CURRENT_ENDPOINT_FILE"
                    warp-cli --accept-tos connect
                    sleep 5
                    parham_warp_status
                fi
                ;;
            13) parham_warp_traffic_tips ;;
            14) parham_warp_check_ipv6_support ;;
            15)
                echo -e "${CYAN}Connection Log:${NC}"
                echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
                tail -20 "$CONNECTION_LOG" 2>/dev/null || echo "No log entries found."
                echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
                echo -e "\n${CYAN}Press Enter to continue...${NC}"
                read -r
                ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                sleep 2
                ;;
        esac
        
        [[ "$choice" != "0" ]] && {
            echo -e "\n${CYAN}Press Enter to return to menu...${NC}"
            read -r
        }
    done
}

# ========== Command Line Arguments ==========
if [[ $# -eq 0 ]]; then
    parham_warp_main_menu
else
    case $1 in
        install) parham_warp_install ;;
        status) parham_warp_status ;;
        connect) parham_warp_connect ;;
        disconnect) parham_warp_disconnect ;;
        test) parham_warp_test_proxy ;;
        scan) parham_warp_scan_cloudflare_ips ;;
        rotate) parham_warp_rotate_endpoint ;;
        ipv6|test-ipv6) parham_warp_check_ipv6_support ;;
        tips) parham_warp_traffic_tips ;;
        log) tail -50 "$CONNECTION_LOG" 2>/dev/null || echo "No log file." ;;
        --help|-h)
            cat << EOF
WARP Manager v${VERSION} - Enhanced Edition

Usage:
  warp-menu                    # Interactive menu
  warp-menu [command]         # Direct command

Commands:
  install       - Install WARP
  status        - Show status
  connect       - Connect to WARP
  disconnect    - Disconnect from WARP
  test          - Test proxy connection
  scan          - Scan Cloudflare IPs
  rotate        - Rotate to next endpoint
  ipv6          - Test IPv6 support
  tips          - Show traffic routing tips
  log           - View connection log
  --help, -h    - Show this help

Examples:
  warp-menu status
  warp-menu test-ipv6
  warp-menu install

EOF
            ;;
        *) parham_warp_main_menu ;;
    esac
fi
