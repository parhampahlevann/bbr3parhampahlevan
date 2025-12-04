#!/usr/bin/env bash
# Cloudflare WARP Menu (Parham Enhanced Edition) - FIXED VERSION
# Author: Parham Pahlevan
# Enhanced with multi-location, IPv6, and bug fixes
# Version: 3.3-parham-fixed

# ========== Elevate to root automatically ==========
if [[ $EUID -ne 0 ]]; then
    echo "[*] Re-running this script as root using sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ========== Auto-install path ==========
SCRIPT_PATH="/usr/local/bin/warp-menu"

# Try to resolve current script path
CURRENT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# Install only if running from a file
if [[ -f "$CURRENT_PATH" && "$CURRENT_PATH" != "$SCRIPT_PATH" ]]; then
    echo "[*] Installing warp-menu to ${SCRIPT_PATH} ..."
    cp -f "$CURRENT_PATH" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "[✓] Installed warp-menu to ${SCRIPT_PATH}"
    echo "[*] You can now run it with: warp-menu"
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
VERSION="3.3-parham-fixed"

# ========== Global files ==========
CONFIG_DIR="/etc/warp-menu"
ENDPOINTS_FILE="${CONFIG_DIR}/endpoints.list"
CURRENT_ENDPOINT_FILE="${CONFIG_DIR}/current_endpoint"
CONNECTION_LOG="${CONFIG_DIR}/connection.log"
WARP_CONFIG_DIR="/var/lib/cloudflare-warp"

# Create directories
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
Japan-1|162.159.147.10:2408
Japan-2|162.159.148.10:2408
Singapore-1|162.159.139.10:2408
Singapore-2|162.159.140.10:2408
Canada-1|162.159.131.10:2408
Canada-2|162.159.132.10:2408
EOF
        echo "[✓] Loaded 16 Cloudflare endpoints from 8 countries."
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
        warp-cli --accept-tos connect
        sleep 3
        if ! parham_warp_is_connected; then
            echo -e "${RED}Cannot establish connection. Please check WARP service.${NC}"
            return 1
        fi
    fi
    return 0
}

# ========== Helper Functions ==========
parham_warp_ensure_proxy_mode() {
    warp-cli --accept-tos set-mode proxy >/dev/null 2>&1 || warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos set-proxy-port 10808 >/dev/null 2>&1 || warp-cli --accept-tos proxy port 10808 >/dev/null 2>&1
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
    )

    for service in "${services[@]}"; do
        ip=$(timeout "$timeout_sec" curl -6 -s --socks5 "${proxy_ip}:${proxy_port}" "$service" 2>/dev/null | tr -d ' \r\n')
        if [[ -n "$ip" && "$ip" =~ : ]]; then
            echo "$ip"
            return 0
        fi
    done

    echo ""
    return 1
}

parham_warp_set_custom_endpoint() {
    local endpoint="$1"
    if [[ -z "$endpoint" ]]; then
        echo -e "${RED}Endpoint is empty.${NC}"
        return 1
    fi

    echo -e "${CYAN}Setting custom endpoint to: ${YELLOW}${endpoint}${NC}"
    log_message "Setting endpoint: $endpoint"

    warp-cli --accept-tos clear-custom-endpoint >/dev/null 2>&1 || true
    sleep 1
    warp-cli --accept-tos set-custom-endpoint "$endpoint"
    sleep 2
}

# ========== Core Functions ==========
parham_warp_install() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                    INSTALL WARP                      ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    # Check if already installed
    if parham_warp_is_installed; then
        echo -e "\n${GREEN}WARP is already installed.${NC}"
        warp-cli --accept-tos status
        return 0
    fi
    
    echo -e "\n${YELLOW}Installing Cloudflare WARP...${NC}"
    
    # Update system and install dependencies
    apt update
    apt install -y curl gpg lsb-release apt-transport-https ca-certificates
    
    # Detect distribution
    local codename
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        codename="$VERSION_CODENAME"
    else
        codename=$(lsb_release -cs 2>/dev/null || echo "")
    fi
    
    # Use jammy for newer Ubuntu versions
    if [[ -z "$codename" || "$codename" == "noble" || "$codename" == "oracular" || "$codename" == "plucky" ]]; then
        codename="jammy"
    fi
    
    echo -e "${YELLOW}Using repository for: $codename${NC}"
    
    # Add Cloudflare WARP repository
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    
    # Install WARP
    apt update
    apt install -y cloudflare-warp
    
    # Initialize WARP
    echo -e "\n${CYAN}Initializing WARP...${NC}"
    
    # Start service
    systemctl start warp-svc
    sleep 5
    
    # Register
    warp-cli --accept-tos registration new || warp-cli --accept-tos register
    sleep 2
    
    # Set proxy mode
    parham_warp_ensure_proxy_mode
    
    # Connect
    warp-cli --accept-tos connect
    sleep 5
    
    # Verify connection
    if parham_warp_is_connected; then
        echo -e "\n${GREEN}✓ WARP installation completed successfully!${NC}"
        echo -e "${YELLOW}Testing IPv4 connectivity through proxy...${NC}"
        
        local ip
        ip=$(parham_warp_get_out_ip)
        if [[ -n "$ip" ]]; then
            echo -e "${GREEN}✓ IPv4 outbound IP: $ip${NC}"
        else
            echo -e "${YELLOW}⚠ Could not get IPv4 through proxy${NC}"
        fi
        
        # Test IPv6
        echo -e "${YELLOW}Testing IPv6 connectivity...${NC}"
        local ipv6
        ipv6=$(parham_warp_get_out_ipv6)
        if [[ -n "$ipv6" ]]; then
            echo -e "${GREEN}✓ IPv6 outbound IP: $ipv6${NC}"
        else
            echo -e "${YELLOW}⚠ IPv6 not available${NC}"
        fi
        
    else
        echo -e "\n${RED}✗ WARP installation completed but failed to connect${NC}"
        echo -e "${YELLOW}Try running: warp-cli --accept-tos connect${NC}"
    fi
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
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

    warp-cli --accept-tos connect
    sleep 3

    if parham_warp_is_connected; then
        echo -e "${GREEN}Connected to WARP${NC}"
        
        # Test connection
        local ip
        ip=$(parham_warp_get_out_ip)
        if [[ -n "$ip" ]]; then
            echo -e "${GREEN}Outbound IPv4: $ip${NC}"
        fi
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
    echo -e "${GREEN}Disconnected${NC}"
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
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
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
        
        # Test proxy connectivity
        echo -e "\n${BOLD}${GREEN}Proxy Tests:${NC}"
        echo -ne "  ${CYAN}• Testing IPv4 proxy...${NC} "
        if timeout 5 curl -4 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Working${NC}"
        else
            echo -e "${RED}✗ Failed${NC}"
        fi
        
        echo -ne "  ${CYAN}• Testing IPv6 proxy...${NC} "
        if timeout 8 curl -6 -s --socks5 127.0.0.1:10808 https://www.cloudflare.com > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Working${NC}"
        else
            echo -e "${YELLOW}⚠ Not available${NC}"
        fi
        
    else
        echo -e "${RED}✗ WARP is not connected${NC}"
    fi
    
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
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
    
    # Test IPv4
    echo -ne "  ${CYAN}• Testing IPv4 connectivity...${NC} "
    local ip4
    ip4=$(parham_warp_get_out_ip)
    if [[ -n "$ip4" ]]; then
        echo -e "${GREEN}✓ Success${NC}"
        echo -e "     ${YELLOW}Outbound IPv4: $ip4${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    
    # Test IPv6
    echo -ne "  ${CYAN}• Testing IPv6 connectivity...${NC} "
    local ip6
    ip6=$(parham_warp_get_out_ipv6)
    if [[ -n "$ip6" ]]; then
        echo -e "${GREEN}✓ Success${NC}"
        echo -e "     ${YELLOW}Outbound IPv6: $ip6${NC}"
    else
        echo -e "${YELLOW}⚠ Not available${NC}"
    fi
    
    # Test websites
    echo -e "\n${BOLD}${GREEN}Testing websites through proxy:${NC}"
    local sites=(
        "Cloudflare:https://www.cloudflare.com"
        "Google:https://www.google.com"
        "GitHub:https://github.com"
    )
    
    for site in "${sites[@]}"; do
        local name="${site%%:*}"
        local url="${site#*:}"
        
        echo -ne "  ${CYAN}• $name...${NC} "
        if timeout 5 curl -4 -s --socks5 127.0.0.1:10808 "$url" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ OK${NC}"
        else
            echo -e "${RED}✗ FAIL${NC}"
        fi
    done
    
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

parham_warp_remove() {
    clear
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
    
    echo -e "\n${GREEN}✓ WARP removed successfully${NC}"
    echo -e "${YELLOW}Note: Configuration files in ${CONFIG_DIR} were kept.${NC}"
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

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
    
    parham_warp_disconnect
    sleep 2
    parham_warp_connect
    sleep 3
    
    new_ip=$(parham_warp_get_out_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}✓ New IP: $new_ip${NC}"
        else
            echo -e "${YELLOW}⚠ IP remained the same: $new_ip${NC}"
        fi
    else
        echo -e "${RED}✗ Failed to get new IP${NC}"
    fi
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
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
    
    systemctl restart warp-svc
    sleep 5
    
    warp-cli --accept-tos registration new || warp-cli --accept-tos register
    parham_warp_ensure_proxy_mode
    warp-cli --accept-tos connect
    sleep 5
    
    new_ip=$(parham_warp_get_out_ip)
    if [[ -n "$new_ip" ]]; then
        echo -e "${GREEN}✓ New Identity IP: $new_ip${NC}"
    else
        echo -e "${RED}✗ Failed to get new IP${NC}"
    fi
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

parham_warp_check_ipv6_support() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}              IPv6 SUPPORT TEST                      ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    
    echo -e "\n${YELLOW}Testing IPv6 support...${NC}\n"
    
    # Test native IPv6
    echo -ne "  ${CYAN}• Native IPv6 connectivity...${NC} "
    if timeout 5 curl -6 -s https://ipv6.google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Working${NC}"
    else
        echo -e "${YELLOW}⚠ Not available${NC}"
    fi
    
    # Test through WARP if connected
    if parham_warp_is_connected; then
        echo -ne "  ${CYAN}• IPv6 through WARP proxy...${NC} "
        local ipv6_out
        ipv6_out=$(parham_warp_get_out_ipv6)
        if [[ -n "$ipv6_out" ]]; then
            echo -e "${GREEN}✓ Working: $ipv6_out${NC}"
        else
            echo -e "${YELLOW}⚠ Not available${NC}"
        fi
    fi
    
    echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

parham_warp_multilocation_menu() {
    while true; do
        clear
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}           MULTI-LOCATION MANAGER                  ${NC}"
        echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
        
        # Show current endpoint
        local current_endpoint="Auto"
        if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
            current_endpoint=$(cat "$CURRENT_ENDPOINT_FILE" 2>/dev/null || true)
        fi
        
        echo -e "\n${GREEN}Current endpoint: ${YELLOW}$current_endpoint${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}\n"
        
        echo -e "${BOLD}${GREEN}Options:${NC}"
        echo -e " ${GREEN}1${NC}) List all endpoints"
        echo -e " ${GREEN}2${NC}) Add new endpoint"
        echo -e " ${GREEN}3${NC}) Apply endpoint"
        echo -e " ${GREEN}4${NC}) Rotate to next endpoint"
        echo -e " ${RED}0${NC}) Back to main menu"
        echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
        
        read -r -p "${YELLOW}Select option: ${NC}" choice
        
        case $choice in
            1)
                clear
                echo -e "${CYAN}Saved endpoints:${NC}"
                echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
                if [[ -s "$ENDPOINTS_FILE" ]]; then
                    cat "$ENDPOINTS_FILE"
                else
                    echo -e "${YELLOW}No endpoints saved${NC}"
                fi
                echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
                ;;
            2)
                clear
                echo -e "${CYAN}Add new endpoint${NC}"
                read -r -p "Name (e.g. Germany-1): " name
                read -r -p "Endpoint (IP:PORT): " endpoint
                
                if [[ -n "$name" && -n "$endpoint" ]]; then
                    echo "$name|$endpoint" >> "$ENDPOINTS_FILE"
                    echo -e "${GREEN}✓ Endpoint added${NC}"
                else
                    echo -e "${RED}✗ Name and endpoint are required${NC}"
                fi
                ;;
            3)
                clear
                if [[ ! -s "$ENDPOINTS_FILE" ]]; then
                    echo -e "${YELLOW}No endpoints saved${NC}"
                else
                    echo -e "${CYAN}Select endpoint:${NC}"
                    select endpoint in $(cat "$ENDPOINTS_FILE"); do
                        if [[ -n "$endpoint" ]]; then
                            local ip_port="${endpoint#*|}"
                            parham_warp_disconnect
                            parham_warp_set_custom_endpoint "$ip_port"
                            echo "$endpoint" > "$CURRENT_ENDPOINT_FILE"
                            warp-cli --accept-tos connect
                            sleep 5
                            echo -e "${GREEN}✓ Endpoint applied${NC}"
                            break
                        fi
                    done
                fi
                ;;
            4)
                if [[ ! -s "$ENDPOINTS_FILE" ]]; then
                    echo -e "${YELLOW}No endpoints saved${NC}"
                else
                    local endpoints=($(cat "$ENDPOINTS_FILE"))
                    local current_index=0
                    
                    if [[ -f "$CURRENT_ENDPOINT_FILE" ]]; then
                        current_endpoint=$(cat "$CURRENT_ENDPOINT_FILE")
                        for i in "${!endpoints[@]}"; do
                            if [[ "${endpoints[$i]}" == "$current_endpoint" ]]; then
                                current_index=$i
                                break
                            fi
                        done
                    fi
                    
                    local next_index=$(( (current_index + 1) % ${#endpoints[@]} ))
                    local next_endpoint="${endpoints[$next_index]}"
                    local next_ip="${next_endpoint#*|}"
                    
                    parham_warp_disconnect
                    parham_warp_set_custom_endpoint "$next_ip"
                    echo "$next_endpoint" > "$CURRENT_ENDPOINT_FILE"
                    warp-cli --accept-tos connect
                    sleep 5
                    echo -e "${GREEN}✓ Rotated to: ${next_endpoint%%|*}${NC}"
                fi
                ;;
            0) break ;;
            *) echo -e "${RED}Invalid option${NC}" ;;
        esac
        
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
    done
}

# ========== Draw Main Menu ==========
parham_warp_draw_menu() {
    clear
    
    # Get current status
    local status_color status_text
    local current_ip="N/A"
    local ipv6_status=""
    
    if parham_warp_is_connected; then
        status_color="$GREEN"
        status_text="CONNECTED"
        current_ip=$(parham_warp_get_out_ip 2>/dev/null || echo "N/A")
        
        # Get IPv6 status
        local ipv6_ip
        ipv6_ip=$(parham_warp_get_out_ipv6 2>/dev/null || echo "")
        if [[ -n "$ipv6_ip" ]]; then
            ipv6_status="${GREEN}✓ IPv6${NC}"
        else
            ipv6_status="${YELLOW}⚠ No IPv6${NC}"
        fi
    else
        status_color="$RED"
        status_text="DISCONNECTED"
        ipv6_status="${YELLOW}─ Not Connected ─${NC}"
    fi
    
    # Draw menu
    cat << EOF
${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}
${CYAN}║       ${BOLD}WARP MANAGER v${VERSION}${NC}                           ${CYAN}║${NC}
${CYAN}║               ${BOLD}by Parham Pahlevan${NC}                        ${CYAN}║${NC}
${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}

${GREEN}┌─ Status ───────────────────────────────────────────────────┐${NC}
${GREEN}│${NC}  Status:     ${status_color}${status_text}${NC}
${GREEN}│${NC}  IPv4:       ${YELLOW}${current_ip}${NC}
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
 ${YELLOW}[9]${NC} Multi-location Manager
 ${YELLOW}[10]${NC} Test IPv6 Support

${RED}[0]${NC} Exit

${CYAN}──────────────────────────────────────────────────────────────${NC}
EOF
}

# ========== Main Menu ==========
parham_warp_main_menu() {
    parham_warp_preload_endpoints
    
    while true; do
        parham_warp_draw_menu
        read -r -p "${YELLOW}Select option [0-10]: ${NC}" choice
        
        case $choice in
            1) parham_warp_install ;;
            2) parham_warp_status ;;
            3) parham_warp_test_proxy ;;
            4) parham_warp_remove ;;
            5) parham_warp_quick_change_ip ;;
            6) parham_warp_new_identity ;;
            7) parham_warp_connect ;;
            8) parham_warp_disconnect ;;
            9) parham_warp_multilocation_menu ;;
            10) parham_warp_check_ipv6_support ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                sleep 2
                ;;
        esac
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
        ipv6|test-ipv6) parham_warp_check_ipv6_support ;;
        --help|-h)
            cat << EOF
WARP Manager v${VERSION}

Usage:
  warp-menu                    # Interactive menu
  warp-menu [command]         # Direct command

Commands:
  install       - Install WARP
  status        - Show status
  connect       - Connect to WARP
  disconnect    - Disconnect from WARP
  test          - Test proxy connection
  ipv6          - Test IPv6 support
  --help, -h    - Show this help

Examples:
  warp-menu status
  warp-menu test
  warp-menu install

EOF
            ;;
        *) parham_warp_main_menu ;;
    esac
fi
