#!/bin/bash

# ========== Basic settings ==========
SCRIPT_NAME="warp-menu"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"

# Use BASH_SOURCE to get real script path (even when called via PATH)
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"

# ========== Auto-install (fixed) ==========
# 1) اگر فایل در /usr/local/bin وجود نداشت، کپی کن
if [[ ! -x "$SCRIPT_PATH" ]]; then
    echo -e "\033[0;33m[!] Installing $SCRIPT_NAME to /usr/local/bin ...\033[0m"
    sudo cp "$SCRIPT_SOURCE" "$SCRIPT_PATH"
    sudo chmod +x "$SCRIPT_PATH"
    echo -e "\033[0;32m[✓] Installed successfully!\033[0m"
fi

# 2) اگر الان از مسیر نصب‌شده اجرا نمی‌شویم، از آن‌جا دوباره اجرا کن
#    این کار باعث می‌شود بعد از نصب، منو به‌درستی بالا بیاید.
if [[ "$(readlink -f "$SCRIPT_SOURCE")" != "$(readlink -f "$SCRIPT_PATH")" ]]; then
    echo -e "\033[0;36m[!] Running WARP Manager from $SCRIPT_PATH ...\033[0m"
    exec sudo "$SCRIPT_PATH" "$@"   # exec: همین پروسه را جایگزین می‌کند
fi

# ========== Colors & Version ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
VERSION="2.1"

# ========== Root Check ==========
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${NC}"
    echo -e "${YELLOW}Please run with: sudo $0${NC}"
    exit 1
fi

# ========== Core Checks ==========
warp_is_installed() {
    command -v warp-cli &>/dev/null
}

warp_is_connected() {
    warp-cli status 2>/dev/null | grep -iq "Connected"
}

# ========== Service Helper ==========
ensure_warp_service() {
    if command -v systemctl &>/dev/null; then
        systemctl enable --now warp-svc 2>/dev/null || systemctl restart warp-svc 2>/dev/null
    fi
}

# ========== Helpers ==========
get_warp_ip() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip

    # Try Cloudflare trace first
    ip=$(timeout 5 curl -s --socks5 "${proxy_ip}:${proxy_port}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')

    if [[ -z "$ip" ]]; then
        # Fallback to ifconfig.me
        ip=$(timeout 5 curl -s --socks5 "${proxy_ip}:${proxy_port}" https://ifconfig.me 2>/dev/null)
    fi

    echo "$ip"
}

# ========== Core Functions ==========
warp_install() {
    if warp_is_installed && warp_is_connected; then
        echo -e "${GREEN}WARP is already installed and connected.${NC}"
        read -p "Do you want to reinstall it? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi

    echo -e "${CYAN}Installing WARP-CLI...${NC}"

    # Get distribution codename
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

    # Handle Ubuntu codenames
    case "$codename" in
        "oracular"|"mantic"|"noble"|"jammy"|"focal")
            codename="jammy"  # Use jammy repo for newer Ubuntu versions
            ;;
    esac

    # Update system
    apt-get update
    apt-get install -y curl gpg lsb-release apt-transport-https ca-certificates

    # Add Cloudflare WARP repository
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" | \
        tee /etc/apt/sources.list.d/cloudflare-client.list

    # Install WARP
    apt-get update
    apt-get install -y cloudflare-warp

    # Start & enable service (اصلی‌ترین بخش برای مشکل سرویس تو)
    ensure_warp_service

    echo -e "${GREEN}WARP installed successfully!${NC}"
    warp_connect
}

warp_connect() {
    if ! warp_is_installed; then
        echo -e "${RED}warp-cli is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${BLUE}Connecting to WARP...${NC}"

    # Check if already registered
    if ! warp-cli account 2>/dev/null | grep -q "Account type"; then
        echo -e "${YELLOW}Registering new WARP account...${NC}"
        warp-cli registration new
    fi

    # Configure proxy mode
    warp-cli mode proxy
    warp-cli proxy port 10808

    # Connect
    warp-cli connect
    sleep 3

    if warp_is_connected; then
        echo -e "${GREEN}Connected to WARP successfully!${NC}"
    else
        echo -e "${RED}Failed to connect to WARP.${NC}"
    fi
}

warp_disconnect() {
    if ! warp_is_installed; then
        echo -e "${RED}warp-cli is not installed.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Disconnecting WARP...${NC}"
    warp-cli disconnect 2>/dev/null
    sleep 1
}

warp_status() {
    if ! warp_is_installed; then
        echo -e "${RED}warp-cli is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}WARP Status:${NC}"
    warp-cli status

    if warp_is_connected; then
        local ip
        ip=$(get_warp_ip)
        if [[ -n "$ip" ]]; then
            echo -e "${GREEN}Proxy IP: $ip${NC}"
        fi
    fi
}

warp_test_proxy() {
    if ! warp_is_installed; then
        echo -e "${RED}warp-cli is not installed.${NC}"
        return 1
    fi

    echo -e "${CYAN}Testing SOCKS5 proxy (127.0.0.1:10808)...${NC}"

    if ! warp_is_connected; then
        echo -e "${RED}WARP is not connected!${NC}"
        return 1
    fi

    local ip
    ip=$(get_warp_ip)
    if [[ -n "$ip" ]]; then
        echo -e "[✓] ${GREEN}Proxy is working!${NC}"
        echo -e "[✓] ${GREEN}Outgoing IP: $ip${NC}"

        # Test connectivity
        echo -e "${CYAN}Testing connectivity...${NC}"
        if timeout 5 curl -s --socks5 127.0.0.1:10808 https://cloudflare.com &>/dev/null; then
            echo -e "[✓] ${GREEN}Internet connectivity: OK${NC}"
        else
            echo -e "[!] ${YELLOW}Connectivity test failed${NC}"
        fi
    else
        echo -e "[✗] ${RED}Proxy test failed${NC}"
    fi
}

warp_remove() {
    echo -e "${RED}Removing WARP...${NC}"
    read -p "Are you sure you want to remove WARP? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if warp_is_installed; then
        warp-cli disconnect 2>/dev/null || true
        sleep 1
    fi

    apt-get remove --purge -y cloudflare-warp
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    apt-get autoremove -y

    echo -e "${GREEN}WARP removed successfully.${NC}"
}

warp_quick_change_ip() {
    if ! warp_is_installed; then
        echo -e "${RED}WARP is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}Changing IP (quick reconnect)...${NC}"
    local old_ip
    old_ip=$(get_warp_ip)
    echo -e "Current IP: ${YELLOW}${old_ip:-N/A}${NC}"

    for attempt in {1..3}; do
        echo -e "Attempt ${attempt}/3..."
        warp_disconnect
        warp-cli connect
        sleep 3

        local new_ip
        new_ip=$(get_warp_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "[✓] ${GREEN}IP changed successfully!${NC}"
            echo -e "[✓] ${GREEN}New IP: $new_ip${NC}"
            return 0
        fi
        sleep 2
    done

    echo -e "${YELLOW}IP did not change. Try 'New Identity' option.${NC}"
    return 2
}

warp_new_identity() {
    if ! warp_is_installed; then
        echo -e "${RED}WARP is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}Creating new identity...${NC}"
    local old_ip
    old_ip=$(get_warp_ip)
    echo -e "Old IP: ${YELLOW}${old_ip:-N/A}${NC}"

    warp_disconnect

    # Delete current registration
    warp-cli registration delete 2>/dev/null || \
    warp-cli clear-keys 2>/dev/null || \
    echo -e "${YELLOW}Note: Could not delete old registration${NC}"

    sleep 2

    # Create new registration
    warp-cli registration new
    warp-cli mode proxy
    warp-cli proxy port 10808
    warp-cli connect

    sleep 4

    local new_ip
    new_ip=$(get_warp_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "[✓] ${GREEN}New identity created!${NC}"
            echo -e "[✓] ${GREEN}New IP: $new_ip${NC}"
        else
            echo -e "${YELLOW}IP address is the same. Try again later.${NC}"
        fi
    else
        echo -e "${RED}Failed to get new IP address.${NC}"
    fi
}

# ========== Menu Display ==========
draw_menu() {
    clear
    echo "========================================================"
    echo "           WARP Proxy Manager v$VERSION"
    echo "                  by Parham Pahlevan"
    echo "========================================================"

    local status="DISCONNECTED"
    local status_color=$RED
    local ip="N/A"

    if warp_is_installed && warp_is_connected; then
        status="CONNECTED"
        status_color=$GREEN
        ip=$(get_warp_ip || echo "N/A")
    elif ! warp_is_installed; then
        status="NOT INSTALLED"
        status_color=$YELLOW
    fi

    echo -e "Status: ${status_color}$status${NC}"
    echo -e "Proxy: 127.0.0.1:10808"
    echo -e "IP Address: ${GREEN}$ip${NC}"
    echo "--------------------------------------------------------"
    echo -e "${YELLOW}OPTIONS:${NC}"
    echo "  1) Install / Reinstall WARP"
    echo "  2) Show Status"
    echo "  3) Test Proxy Connection"
    echo "  4) Remove WARP"
    echo "  5) Change IP (Quick)"
    echo "  6) Change IP (New Identity)"
    echo "  0) Exit"
    echo "========================================================"
    echo -ne "${YELLOW}Select option [0-6]: ${NC}"
}

# ========== Main Menu ==========
main_menu() {
    while true; do
        draw_menu
        read -r choice

        case $choice in
            1) warp_install ;;
            2) warp_status ;;
            3) warp_test_proxy ;;
            4) warp_remove ;;
            5) warp_quick_change_ip ;;
            6) warp_new_identity ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option! Please choose 0-6.${NC}"
                ;;
        esac

        if [[ $choice != "0" ]]; then
            echo -e "\n${YELLOW}Press Enter to continue...${NC}"
            read -r
        fi
    done
}

# ========== Start Program ==========
main_menu
