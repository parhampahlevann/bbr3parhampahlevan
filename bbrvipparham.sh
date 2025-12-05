#!/usr/bin/env bash
# Cloudflare WARP Menu (Parham Enhanced Edition) - Clean Version
# Author: Parham Pahlevan
# Version: 4.0-clean

# ========== Elevate to root automatically ==========
if [[ $EUID -ne 0 ]]; then
    echo "[*] Re-running this script as root using sudo..."
    exec sudo -E bash "$0" "$@"
fi

# ========== Colors ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ========== Config ==========
CONFIG_DIR="/etc/warp-menu"
ENDPOINTS_FILE="${CONFIG_DIR}/endpoints.list"
VERSION="4.0"

# Create directory
mkdir -p "$CONFIG_DIR"

# ========== Core Checks ==========
warp_is_installed() {
    command -v warp-cli &>/dev/null
}

warp_is_connected() {
    warp-cli --accept-tos status 2>/dev/null | grep -iq "Connected"
}

# ========== Helper Functions ==========
get_out_ip() {
    curl -4 -s --socks5 127.0.0.1:10808 https://api.ipify.org 2>/dev/null || echo "N/A"
}

get_out_ipv6() {
    curl -6 -s --socks5 127.0.0.1:10808 https://api64.ipify.org 2>/dev/null || echo "N/A"
}

ensure_proxy_mode() {
    warp-cli --accept-tos set-mode proxy >/dev/null 2>&1
    warp-cli --accept-tos set-proxy-port 10808 >/dev/null 2>&1
    sleep 1
}

# ========== Main Functions ==========
install_warp() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}          INSTALL WARP               ${NC}"
    echo -e "${CYAN}============================================${NC}\n"
    
    if warp_is_installed; then
        echo -e "${GREEN}WARP is already installed.${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Installing Cloudflare WARP...${NC}\n"
    
    # Update and install dependencies
    apt update
    apt install -y curl gpg
    
    # Add repository
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    
    # Detect OS version
    if grep -q "jammy\|focal\|bionic" /etc/os-release; then
        codename="jammy"
    else
        codename="jammy"
    fi
    
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" | tee /etc/apt/sources.list.d/cloudflare-client.list
    
    # Install
    apt update
    apt install -y cloudflare-warp
    
    # Start service
    systemctl start warp-svc
    sleep 5
    
    # Register and connect
    warp-cli --accept-tos registration new
    ensure_proxy_mode
    warp-cli --accept-tos connect
    sleep 5
    
    if warp_is_connected; then
        echo -e "\n${GREEN}✓ WARP installed successfully!${NC}"
        local ip=$(get_out_ip)
        echo -e "${GREEN}Your WARP IP: $ip${NC}"
    else
        echo -e "\n${RED}✗ Installation failed${NC}"
    fi
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

status_warp() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}          WARP STATUS                ${NC}"
    echo -e "${CYAN}============================================${NC}\n"
    
    if warp_is_installed; then
        echo -e "${GREEN}WARP Status:${NC}"
        warp-cli --accept-tos status
    else
        echo -e "${RED}WARP is not installed${NC}"
    fi
    
    echo -e "\n${GREEN}Connection Details:${NC}"
    
    if warp_is_connected; then
        local ip4=$(get_out_ip)
        local ip6=$(get_out_ipv6)
        
        echo -e "  IPv4: ${YELLOW}$ip4${NC}"
        echo -e "  IPv6: ${YELLOW}$ip6${NC}"
        
        # Test proxy
        echo -ne "\n${CYAN}Testing proxy...${NC} "
        if curl -4 -s --socks5 127.0.0.1:10808 https://cloudflare.com >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Working${NC}"
        else
            echo -e "${RED}✗ Failed${NC}"
        fi
    else
        echo -e "${RED}Not connected${NC}"
    fi
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

test_proxy() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}          PROXY TEST                 ${NC}"
    echo -e "${CYAN}============================================${NC}\n"
    
    if ! warp_is_connected; then
        echo -e "${RED}WARP is not connected${NC}"
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    echo -e "${GREEN}Testing SOCKS5 proxy (127.0.0.1:10808)...${NC}\n"
    
    echo -ne "${CYAN}• IPv4 test...${NC} "
    local ip4=$(get_out_ip)
    if [[ "$ip4" != "N/A" ]]; then
        echo -e "${GREEN}✓ $ip4${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    
    echo -ne "${CYAN}• IPv6 test...${NC} "
    local ip6=$(get_out_ipv6)
    if [[ "$ip6" != "N/A" ]]; then
        echo -e "${GREEN}✓ $ip6${NC}"
    else
        echo -e "${YELLOW}⚠ Not available${NC}"
    fi
    
    echo -e "\n${CYAN}• Website tests:${NC}"
    local sites=("cloudflare.com" "google.com" "github.com")
    
    for site in "${sites[@]}"; do
        echo -ne "  $site... "
        if curl -4 -s --socks5 127.0.0.1:10808 "https://$site" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC}"
        fi
    done
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

connect_warp() {
    echo -e "\n${CYAN}Connecting to WARP...${NC}"
    warp-cli --accept-tos connect
    sleep 3
    
    if warp_is_connected; then
        echo -e "${GREEN}✓ Connected${NC}"
    else
        echo -e "${RED}✗ Connection failed${NC}"
    fi
    sleep 2
}

disconnect_warp() {
    echo -e "\n${CYAN}Disconnecting from WARP...${NC}"
    warp-cli --accept-tos disconnect
    sleep 2
    echo -e "${GREEN}✓ Disconnected${NC}"
    sleep 1
}

change_ip() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}          CHANGE IP                  ${NC}"
    echo -e "${CYAN}============================================${NC}\n"
    
    if ! warp_is_connected; then
        echo -e "${RED}WARP is not connected${NC}"
        echo -e "\n${CYAN}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    local old_ip=$(get_out_ip)
    echo -e "Current IP: ${YELLOW}$old_ip${NC}"
    
    echo -e "\n${CYAN}Changing IP...${NC}"
    disconnect_warp
    connect_warp
    
    local new_ip=$(get_out_ip)
    echo -e "\nNew IP: ${YELLOW}$new_ip${NC}"
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

new_identity() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}          NEW IDENTITY              ${NC}"
    echo -e "${CYAN}============================================${NC}\n"
    
    echo -e "${YELLOW}This will reset your WARP connection...${NC}\n"
    read -r -p "Continue? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    echo -e "\n${CYAN}Resetting WARP...${NC}"
    
    warp-cli --accept-tos disconnect
    warp-cli --accept-tos registration delete
    sleep 2
    
    systemctl restart warp-svc
    sleep 5
    
    warp-cli --accept-tos registration new
    ensure_proxy_mode
    warp-cli --accept-tos connect
    sleep 5
    
    if warp_is_connected; then
        local new_ip=$(get_out_ip)
        echo -e "${GREEN}✓ New identity created${NC}"
        echo -e "${GREEN}New IP: $new_ip${NC}"
    else
        echo -e "${RED}✗ Failed to create new identity${NC}"
    fi
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

test_ipv6() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}          IPv6 TEST                 ${NC}"
    echo -e "${CYAN}============================================${NC}\n"
    
    echo -e "${GREEN}Testing IPv6 connectivity...${NC}\n"
    
    echo -ne "${CYAN}• Native IPv6...${NC} "
    if curl -6 -s https://ipv6.google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Available${NC}"
    else
        echo -e "${YELLOW}⚠ Not available${NC}"
    fi
    
    if warp_is_connected; then
        echo -ne "${CYAN}• IPv6 through WARP...${NC} "
        local ipv6=$(get_out_ipv6)
        if [[ "$ipv6" != "N/A" ]]; then
            echo -e "${GREEN}✓ $ipv6${NC}"
        else
            echo -e "${YELLOW}⚠ Not available${NC}"
        fi
    fi
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

remove_warp() {
    clear
    echo -e "${RED}============================================${NC}"
    echo -e "${BOLD}${RED}          REMOVE WARP               ${NC}"
    echo -e "${RED}============================================${NC}\n"
    
    echo -e "${YELLOW}⚠ This will remove WARP completely!${NC}\n"
    read -r -p "Are you sure? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Cancelled${NC}"
        sleep 2
        return
    fi
    
    echo -e "\n${CYAN}Removing WARP...${NC}"
    
    warp-cli --accept-tos disconnect 2>/dev/null || true
    systemctl stop warp-svc 2>/dev/null || true
    
    apt remove --purge -y cloudflare-warp 2>/dev/null || true
    
    rm -f /etc/apt/sources.list.d/cloudflare-client.list 2>/dev/null || true
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null || true
    
    echo -e "\n${GREEN}✓ WARP removed successfully${NC}"
    
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

# ========== Draw Menu ==========
show_menu() {
    clear
    
    # Get status
    local status_ip="N/A"
    local status_color=$RED
    local status_text="DISCONNECTED"
    
    if warp_is_connected; then
        status_color=$GREEN
        status_text="CONNECTED"
        status_ip=$(get_out_ip)
    fi
    
    # Draw clean menu
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    ${BOLD}CLOUDFLARE WARP MENU v$VERSION${NC}         ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${BOLD}Status:${NC} ${status_color}${status_text}${NC}"
    echo -e "${BOLD}IP:${NC} ${YELLOW}$status_ip${NC}\n"
    
    echo -e "${BOLD}${GREEN}MAIN OPTIONS:${NC}"
    echo -e " ${GREEN}1${NC}) Install WARP"
    echo -e " ${GREEN}2${NC}) Status"
    echo -e " ${GREEN}3${NC}) Test Proxy"
    echo -e " ${GREEN}4${NC}) Remove WARP\n"
    
    echo -e "${BOLD}${CYAN}CONNECTION:${NC}"
    echo -e " ${CYAN}5${NC}) Connect"
    echo -e " ${CYAN}6${NC}) Disconnect"
    echo -e " ${CYAN}7${NC}) Change IP"
    echo -e " ${CYAN}8${NC}) New Identity\n"
    
    echo -e "${BOLD}${YELLOW}TOOLS:${NC}"
    echo -e " ${YELLOW}9${NC}) Test IPv6\n"
    
    echo -e "${BOLD}${RED}0${NC}) Exit\n"
    
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
}

# ========== Main Loop ==========
main() {
    # Auto-install if needed
    if [[ ! -f "/usr/local/bin/warp-menu" ]]; then
        echo -e "${CYAN}Installing warp-menu to /usr/local/bin...${NC}"
        cp "$0" /usr/local/bin/warp-menu
        chmod +x /usr/local/bin/warp-menu
        echo -e "${GREEN}✓ Installed. Run with: warp-menu${NC}\n"
    fi
    
    while true; do
        show_menu
        
        echo -ne "${YELLOW}Select option [0-9]: ${NC}"
        read -r choice
        
        case $choice in
            1) install_warp ;;
            2) status_warp ;;
            3) test_proxy ;;
            4) remove_warp ;;
            5) connect_warp ;;
            6) disconnect_warp ;;
            7) change_ip ;;
            8) new_identity ;;
            9) test_ipv6 ;;
            0)
                echo -e "\n${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "\n${RED}Invalid option!${NC}"
                sleep 2
                ;;
        esac
    done
}

# Run main function
main
