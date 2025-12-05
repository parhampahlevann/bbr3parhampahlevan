#!/bin/bash

###############################################################################
# Cloudflare WARP Proxy Manager
# - Auto-installs itself to /usr/local/bin/warp-menu
# - Installs Cloudflare WARP (cloudflare-warp)
# - Uses warp-cli in proxy mode (SOCKS5 127.0.0.1:10808)
# - Provides menu to install, connect, change IP, remove, etc.
###############################################################################

SCRIPT_NAME="warp-menu"
INSTALL_PATH="/usr/local/bin/$SCRIPT_NAME"

# Resolve script source (works even if called via symlink or from PATH)
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_REALPATH="$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null || realpath "$SCRIPT_SOURCE" 2>/dev/null || echo "$SCRIPT_SOURCE")"

# ===================== Auto-install to /usr/local/bin ========================

# 1) If /usr/local/bin/warp-menu does not exist or is not executable, install it
if [[ ! -x "$INSTALL_PATH" ]]; then
    echo -e "\033[0;33m[!] Installing $SCRIPT_NAME to $INSTALL_PATH ...\033[0m"
    if ! command -v sudo &>/dev/null && [[ $EUID -ne 0 ]]; then
        echo -e "\033[0;31m[ERROR] 'sudo' not found and you are not root.\033[0m"
        echo "Please run as root."
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        sudo cp "$SCRIPT_REALPATH" "$INSTALL_PATH"
        sudo chmod +x "$INSTALL_PATH"
    else
        cp "$SCRIPT_REALPATH" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
    fi
    echo -e "\033[0;32m[✓] Installed successfully.\033[0m"
fi

# 2) If we are not running from the installed path, re-exec from there
INSTALLED_REALPATH="$(readlink -f "$INSTALL_PATH" 2>/dev/null || echo "$INSTALL_PATH")"
if [[ "$SCRIPT_REALPATH" != "$INSTALLED_REALPATH" ]]; then
    echo -e "\033[0;36m[>] Re-launching from $INSTALL_PATH ...\033[0m"
    exec sudo "$INSTALL_PATH" "$@"
fi

# ===================== Colors & Version =====================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
VERSION="3.0"

# ===================== Root Check ===========================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root.${NC}"
    echo -e "${YELLOW}Usage: sudo $SCRIPT_NAME${NC}"
    exit 1
fi

# ===================== Basic Checks =========================================

warp_is_installed() {
    command -v warp-cli &>/dev/null
}

warp_is_connected() {
    warp-cli status 2>/dev/null | grep -iq "Connected"
}

# ===================== Service Helpers ======================================

ensure_warp_service() {
    # Start and enable Cloudflare WARP service
    if command -v systemctl &>/dev/null; then
        systemctl enable --now warp-svc 2>/dev/null || systemctl restart warp-svc 2>/dev/null
    elif command -v service &>/dev/null; then
        service warp-svc start 2>/dev/null || service warp-svc restart 2>/dev/null
    fi
}

# ===================== IP / Proxy Helper ====================================

get_warp_ip() {
    local proxy_ip="127.0.0.1"
    local proxy_port="10808"
    local ip

    # Try Cloudflare trace first
    if command -v timeout &>/dev/null; then
        ip=$(timeout 5 curl -s --socks5 "${proxy_ip}:${proxy_port}" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | \
            awk -F= '/^ip=/{print $2}')
    else
        ip=$(curl -s --max-time 5 --socks5 "${proxy_ip}:${proxy_port}" \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | \
            awk -F= '/^ip=/{print $2}')
    fi

    if [[ -z "$ip" ]]; then
        # Fallback to ifconfig.me
        if command -v timeout &>/dev/null; then
            ip=$(timeout 5 curl -s --socks5 "${proxy_ip}:${proxy_port}" https://ifconfig.me 2>/dev/null)
        else
            ip=$(curl -s --max-time 5 --socks5 "${proxy_ip}:${proxy_port}" https://ifconfig.me 2>/dev/null)
        fi
    fi

    echo "$ip"
}

# ===================== Core Actions =========================================

warp_install() {
    if warp_is_installed; then
        echo -e "${GREEN}[INFO] Cloudflare WARP is already installed.${NC}"
        read -rp "Do you want to reinstall it? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    fi

    echo -e "${CYAN}[+] Installing Cloudflare WARP (warp-cli)...${NC}"

    # Determine distribution codename
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

    # Force supported codename for newer Ubuntu versions
    case "$codename" in
        oracular|mantic|noble|jammy|focal)
            codename="jammy"
            ;;
    esac

    apt-get update
    apt-get install -y curl gpg lsb-release apt-transport-https ca-certificates

    # Add Cloudflare WARP repository
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $codename main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update
    apt-get install -y cloudflare-warp

    ensure_warp_service

    echo -e "${GREEN}[✓] Cloudflare WARP installed successfully.${NC}"
    warp_connect
}

warp_connect() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi

    ensure_warp_service
    echo -e "${BLUE}[*] Connecting to Cloudflare WARP...${NC}"

    # Create registration if needed
    if ! warp-cli account 2>/dev/null | grep -q "Account type"; then
        echo -e "${YELLOW}[INFO] Creating new WARP account registration...${NC}"
        warp-cli registration new
    fi

    # Set proxy mode and port
    warp-cli mode proxy
    warp-cli proxy port 10808

    # Connect
    warp-cli connect
    sleep 3

    if warp_is_connected; then
        echo -e "${GREEN}[✓] Connected to WARP successfully.${NC}"
    else
        echo -e "${RED}[!] Failed to connect to WARP.${NC}"
    fi
}

warp_disconnect() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi
    echo -e "${YELLOW}[*] Disconnecting WARP...${NC}"
    warp-cli disconnect 2>/dev/null || true
    sleep 1
}

warp_status() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}===== WARP Status =====${NC}"
    warp-cli status

    if warp_is_connected; then
        local ip
        ip=$(get_warp_ip)
        [[ -n "$ip" ]] && echo -e "${GREEN}Proxy IP (via Cloudflare): $ip${NC}"
    fi
}

warp_test_proxy() {
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] warp-cli is not installed.${NC}"
        return 1
    fi

    echo -e "${CYAN}[*] Testing SOCKS5 proxy 127.0.0.1:10808 ...${NC}"

    if ! warp_is_connected; then
        echo -e "${RED}[ERROR] WARP is not connected. Please connect first.${NC}"
        return 1
    fi

    local ip
    ip=$(get_warp_ip)
    if [[ -n "$ip" ]]; then
        echo -e "${GREEN}[✓] Proxy is working. Outgoing IP: $ip${NC}"

        echo -e "${CYAN}[*] Testing HTTPS connectivity through Cloudflare...${NC}"
        if command -v timeout &>/dev/null; then
            if timeout 5 curl -s --socks5 127.0.0.1:10808 https://www.cloudflare.com &>/dev/null; then
                echo -e "${GREEN}[✓] Internet connectivity via WARP is OK.${NC}"
            else
                echo -e "${YELLOW}[!] Connectivity test failed (Cloudflare site not reachable).${NC}"
            fi
        else
            if curl -s --max-time 5 --socks5 127.0.0.1:10808 https://www.cloudflare.com &>/dev/null; then
                echo -e "${GREEN}[✓] Internet connectivity via WARP is OK.${NC}"
            else
                echo -e "${YELLOW}[!] Connectivity test failed (Cloudflare site not reachable).${NC}"
            fi
        fi
    else
        echo -e "${RED}[!] Failed to detect outgoing IP. Proxy test failed.${NC}"
    fi
}

warp_remove() {
    echo -e "${RED}[WARNING] This will remove Cloudflare WARP from your system.${NC}"
    read -rp "Are you sure you want to continue? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    if warp_is_installed; then
        warp_disconnect
    fi

    apt-get remove --purge -y cloudflare-warp || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    apt-get autoremove -y

    echo -e "${GREEN}[✓] Cloudflare WARP has been removed.${NC}"
}

# ===================== Cloudflare IP Change Options ==========================

warp_change_ip_quick() {
    # Quick IP change: disconnect + reconnect with same identity
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] WARP is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}[*] Changing Cloudflare IP (quick reconnect)...${NC}"
    local old_ip new_ip

    old_ip=$(get_warp_ip)
    echo -e "Current IP: ${YELLOW}${old_ip:-N/A}${NC}"

    for attempt in {1..3}; do
        echo -e "Attempt ${attempt}/3 ..."
        warp_disconnect
        warp-cli connect
        sleep 3

        new_ip=$(get_warp_ip)
        if [[ -n "$new_ip" && "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}[✓] IP changed successfully! New IP: $new_ip${NC}"
            return 0
        fi
        sleep 2
    done

    echo -e "${YELLOW}[!] IP did not change after quick reconnect attempts.${NC}"
    echo -e "${YELLOW}[>] Try 'Change IP (New Identity)' for a stronger change.${NC}"
    return 2
}

warp_change_ip_new_identity() {
    # Strong IP change: delete registration and create a new account
    if ! warp_is_installed; then
        echo -e "${RED}[ERROR] WARP is not installed.${NC}"
        return 1
    fi

    ensure_warp_service

    echo -e "${CYAN}[*] Creating a NEW Cloudflare WARP identity (new registration)...${NC}"
    local old_ip new_ip
    old_ip=$(get_warp_ip)
    echo -e "Old IP: ${YELLOW}${old_ip:-N/A}${NC}"

    warp_disconnect

    echo -e "${YELLOW}[*] Deleting current WARP registration (if any)...${NC}"
    warp-cli registration delete 2>/dev/null || \
    warp-cli clear-keys 2>/dev/null || \
    echo -e "${YELLOW}[!] Could not fully delete old registration (continuing).${NC}"

    sleep 2

    echo -e "${CYAN}[*] Registering a brand new WARP account...${NC}"
    warp-cli registration new
    warp-cli mode proxy
    warp-cli proxy port 10808
    warp-cli connect
    sleep 4

    new_ip=$(get_warp_ip)
    if [[ -n "$new_ip" ]]; then
        if [[ "$new_ip" != "$old_ip" ]]; then
            echo -e "${GREEN}[✓] New identity created successfully! New IP: $new_ip${NC}"
        else
            echo -e "${YELLOW}[!] New identity created, but IP appears the same. Try again later.${NC}"
        fi
    else
        echo -e "${RED}[!] Failed to obtain new IP address after registration.${NC}"
    fi
}

# ===================== Menu UI ==============================================

draw_menu() {
    clear
    echo "=================================================================="
    echo "                Cloudflare WARP Proxy Manager v$VERSION"
    echo "                        by Parham Pahlevan"
    echo "=================================================================="

    local status="NOT INSTALLED"
    local status_color=$YELLOW
    local ip="N/A"

    if warp_is_installed; then
        if warp_is_connected; then
            status="CONNECTED"
            status_color=$GREEN
            ip=$(get_warp_ip || echo "N/A")
        else
            status="DISCONNECTED"
            status_color=$RED
        fi
    fi

    echo -e "Status      : ${status_color}$status${NC}"
    echo -e "Proxy       : 127.0.0.1:10808 (SOCKS5)"
    echo -e "IP (via WARP): ${GREEN}$ip${NC}"
    echo "------------------------------------------------------------------"
    echo -e "${YELLOW}OPTIONS:${NC}"
    echo "  1) Install / Reinstall Cloudflare WARP"
    echo "  2) Connect WARP"
    echo "  3) Disconnect WARP"
    echo "  4) Show Status"
    echo "  5) Test Proxy Connection"
    echo "  6) Change IP (Quick Reconnect)"
    echo "  7) Change IP (New Identity / New Registration)"
    echo "  8) Remove Cloudflare WARP"
    echo "  0) Exit"
    echo "=================================================================="
    echo -ne "${YELLOW}Select an option [0-8]: ${NC}"
}

main_menu() {
    while true; do
        draw_menu
        read -r choice

        case "$choice" in
            1) warp_install ;;
            2) warp_connect ;;
            3) warp_disconnect ;;
            4) warp_status ;;
            5) warp_test_proxy ;;
            6) warp_change_ip_quick ;;
            7) warp_change_ip_new_identity ;;
            8) warp_remove ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option. Please choose 0–8.${NC}"
                ;;
        esac

        if [[ "$choice" != "0" ]]; then
            echo
            echo -e "${YELLOW}Press Enter to return to the menu...${NC}"
            read -r
        fi
    done
}

# ===================== Start Program ========================================

main_menu
