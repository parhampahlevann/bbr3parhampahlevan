#!/bin/bash
# Global Configuration
SCRIPT_NAME="BBR VIP Optimizer Pro"
SCRIPT_VERSION="4.1"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
SYSCTL_BACKUP="/etc/sysctl.conf.bak"
CRON_JOB_FILE="/etc/cron.d/bbr_vip_autoreset"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
VIP_MODE=false
VIP_SUBNET=""
VIP_GATEWAY=""
DEFAULT_MTU=1420
CURRENT_MTU=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo $DEFAULT_MTU)
DNS_SERVERS=("1.1.1.1" "8.8.8.8")
CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
OS=""
VER=""
# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1
# Color Codes
RED='\033[0;31m'
BOLD_RED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
# Header Display
show_header() {
    clear
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗"
    echo -e "║   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}              ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Network Interface: ${BOLD}$NETWORK_INTERFACE${NC}"
    echo -e "${YELLOW}VIP Mode: ${BOLD}$([ "$VIP_MODE" = true ] && echo "Enabled" || echo "Disabled")${NC}"
    echo -e "${YELLOW}Current MTU: ${BOLD}$CURRENT_MTU${NC}"
    echo -e "${YELLOW}Current DNS: ${BOLD}$CURRENT_DNS${NC}"
    echo -e "${YELLOW}OS Detected: ${BOLD}$OS $VER${NC}\n"
}
# Check Root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${BOLD_RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
}
# Detect Distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$DISTRIB_ID
        VER=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        OS=Debian
        VER=$(cat /etc/debian_version)
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
}
# Detect Network Manager
detect_network_manager() {
    if [ -d /etc/netplan ] && [ -n "$(ls -A /etc/netplan/*.yaml 2>/dev/null)" ]; then
        echo "netplan"
    elif [ -d /etc/systemd/network ] && systemctl is-active --quiet systemd-networkd; then
        echo "systemd-networkd"
    elif systemctl is-active --quiet NetworkManager; then
        echo "networkmanager"
    elif [ -f /etc/network/interfaces ]; then
        echo "ifupdown"
    else
        echo "unknown"
    fi
}
# Set MTU Persistently
set_mtu_persistent() {
    local interface=$1
    local mtu=$2
    local manager=$(detect_network_manager)
    
    case $manager in
        netplan)
            local netplan_file=$(ls /etc/netplan/*.yaml | head -1)
            if [ -n "$netplan_file" ]; then
                cp "$netplan_file" "${netplan_file}.bak"
                
                # Remove existing MTU setting for the interface
                sed -i "/$interface:/,/^[^ ]/ {
                    /mtu:/d
                }" "$netplan_file"
                
                # Add new MTU setting
                sed -i "/$interface:/a\      mtu: $mtu" "$netplan_file"
                
                netplan apply
                echo "MTU set persistently via Netplan."
            else
                echo "No Netplan configuration file found. Using temporary method."
                ip link set dev $interface mtu $mtu
            fi
            ;;
        systemd-networkd)
            local network_file="/etc/systemd/network/10-${interface}.network"
            [ -f "$network_file" ] && cp "$network_file" "${network_file}.bak"
            
            cat > "$network_file" <<EOF
[Match]
Name=$interface

[Network]
DHCP=yes

[Link]
MTUBytes=$mtu
EOF
            
            systemctl restart systemd-networkd
            echo "MTU set persistently via systemd-networkd."
            ;;
        networkmanager)
            nmcli connection modify "$interface" ipv4.mtu "$mtu"
            nmcli connection up "$interface"
            echo "MTU set persistently via NetworkManager."
            ;;
        ifupdown)
            local interfaces_file="/etc/network/interfaces"
            cp "$interfaces_file" "${interfaces_file}.bak"
            
            # Remove existing MTU setting
            sed -i "/iface $interface inet/,/^$/ {
                /mtu /d
            }" "$interfaces_file"
            
            # Add new MTU setting
            sed -i "/iface $interface inet/a\    mtu $mtu" "$interfaces_file"
            
            ifdown $interface && ifup $interface
            echo "MTU set persistently via ifupdown."
            ;;
        *)
            echo "Unknown network manager. Using temporary method."
            ip link set dev $interface mtu $mtu
            ;;
    esac
}
# Set DNS Persistently
set_dns_persistent() {
    local dns_servers=("$@")
    local manager=$(detect_network_manager)
    local dns_csv=$(IFS=,; echo "${dns_servers[*]}")
    
    case $manager in
        netplan)
            local netplan_file=$(ls /etc/netplan/*.yaml | head -1)
            if [ -n "$netplan_file" ]; then
                cp "$netplan_file" "${netplan_file}.bak"
                
                # Remove existing DNS settings
                sed -i "/$NETWORK_INTERFACE:/,/^[^ ]/ {
                    /nameservers:/,/^[^ ]/d
                }" "$netplan_file"
                
                # Add new DNS settings
                sed -i "/$NETWORK_INTERFACE:/a\      nameservers:\n        addresses: [$dns_csv]" "$netplan_file"
                
                netplan apply
                echo "DNS set persistently via Netplan."
            else
                echo "No Netplan configuration file found. Using temporary method."
                update_dns_temp
            fi
            ;;
        systemd-networkd)
            local network_file="/etc/systemd/network/10-${NETWORK_INTERFACE}.network"
            [ -f "$network_file" ] && cp "$network_file" "${network_file}.bak"
            
            cat > "$network_file" <<EOF
[Match]
Name=$NETWORK_INTERFACE

[Network]
DHCP=yes
DNS=$dns_csv

[Link]
MTUBytes=$CURRENT_MTU
EOF
            
            systemctl restart systemd-networkd
            echo "DNS set persistently via systemd-networkd."
            ;;
        networkmanager)
            nmcli connection modify "$NETWORK_INTERFACE" ipv4.dns "$dns_csv"
            nmcli connection up "$NETWORK_INTERFACE"
            echo "DNS set persistently via NetworkManager."
            ;;
        ifupdown)
            local interfaces_file="/etc/network/interfaces"
            cp "$interfaces_file" "${interfaces_file}.bak"
            
            # Remove existing DNS settings
            sed -i "/iface $NETWORK_INTERFACE inet/,/^$/ {
                /dns-nameservers /d
            }" "$interfaces_file"
            
            # Add new DNS settings
            sed -i "/iface $NETWORK_INTERFACE inet/a\    dns-nameservers ${dns_servers[*]}" "$interfaces_file"
            
            ifdown $NETWORK_INTERFACE && ifup $NETWORK_INTERFACE
            echo "DNS set persistently via ifupdown."
            ;;
        *)
            echo "Unknown network manager. Using temporary method."
            update_dns_temp
            ;;
    esac
}
# Update DNS Configuration (Temporary)
update_dns_temp() {
    echo "# Generated by $SCRIPT_NAME" > /etc/resolv.conf
    for dns in "${DNS_SERVERS[@]}"; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    CURRENT_DNS="${DNS_SERVERS[@]}"
}
# Load Configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        # Default values
        ENABLE_BBR=true
        ENABLE_FASTOPEN=true
        TCP_CONGESTION="bbr"
        TCP_FASTOPEN=3
        VIP_MODE=false
        VIP_SUBNET=""
        VIP_GATEWAY=""
        DEFAULT_KERNEL_PARAMS=(
            "net.core.default_qdisc=fq"
            "net.ipv4.tcp_congestion_control=$TCP_CONGESTION"
            "net.ipv4.tcp_fastopen=$TCP_FASTOPEN"
            "net.ipv4.tcp_syncookies=1"
            "net.ipv4.tcp_tw_reuse=1"
            "net.ipv4.tcp_fin_timeout=30"
            "net.ipv4.tcp_keepalive_time=1200"
            "net.ipv4.ip_local_port_range=1024 65000"
            "net.ipv4.tcp_max_syn_backlog=8192"
            "net.ipv4.tcp_max_tw_buckets=5000"
            "net.core.somaxconn=65535"
            "net.core.netdev_max_backlog=16384"
            "net.ipv4.tcp_slow_start_after_idle=0"
            "net.ipv4.tcp_mtu_probing=1"
            "net.ipv4.tcp_rfc1337=1"
        )
        VIP_KERNEL_PARAMS=(
            "net.ipv4.tcp_window_scaling=1"
            "net.ipv4.tcp_timestamps=1"
            "net.ipv4.tcp_sack=1"
            "net.ipv4.tcp_dsack=1"
            "net.ipv4.tcp_fack=1"
            "net.ipv4.tcp_adv_win_scale=1"
            "net.ipv4.tcp_app_win=31"
            "net.ipv4.tcp_low_latency=1"
        )
        
        # Apply default MTU using persistent method
        set_mtu_persistent "$NETWORK_INTERFACE" "$DEFAULT_MTU"
        CURRENT_MTU=$DEFAULT_MTU
        
        # Apply default DNS using persistent method
        set_dns_persistent "${DNS_SERVERS[@]}"
        
        save_config
    fi
}
# Update DNS Configuration (Legacy - kept for compatibility)
update_dns() {
    set_dns_persistent "${DNS_SERVERS[@]}"
}
# Backup current sysctl settings
backup_sysctl() {
    if [[ ! -f "$SYSCTL_BACKUP" ]]; then
        cp /etc/sysctl.conf "$SYSCTL_BACKUP"
        echo -e "${GREEN}Current sysctl configuration backed up to $SYSCTL_BACKUP${NC}"
    fi
}
# Apply Kernel Parameters
apply_kernel_params() {
    echo -e "${YELLOW}Applying optimized kernel parameters...${NC}"
    
    # Create temp file
    local temp_file=$(mktemp)
    
    # Process existing sysctl.conf
    while IFS= read -r line; do
        # Skip existing parameters we want to replace
        local skip_line=false
        for param in "${DEFAULT_KERNEL_PARAMS[@]}" "${VIP_KERNEL_PARAMS[@]}"; do
            key=$(echo "$param" | cut -d= -f1)
            if [[ "$line" == "$key"* ]]; then
                skip_line=true
                break
            fi
        done
        $skip_line || echo "$line" >> "$temp_file"
    done < /etc/sysctl.conf
    
    # Add new parameters
    {
        echo -e "\n# Added by $SCRIPT_NAME"
        # Default parameters
        for param in "${DEFAULT_KERNEL_PARAMS[@]}"; do
            echo "$param"
        done
        
        # VIP parameters if enabled
        if [ "$VIP_MODE" = true ]; then
            echo -e "\n# VIP Optimization Parameters"
            for param in "${VIP_KERNEL_PARAMS[@]}"; do
                echo "$param"
            done
        fi
    } >> "$temp_file"
    
    # Replace sysctl.conf
    mv "$temp_file" /etc/sysctl.conf
    
    # Apply changes
    if ! sysctl -p >/dev/null 2>&1; then
        echo -e "${BOLD_RED}Error applying sysctl settings!${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Kernel parameters applied successfully!${NC}"
    return 0
}
# Verify BBR Status
verify_bbr() {
    echo -e "${YELLOW}Verifying BBR status...${NC}"
    
    local current_congestion=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null)
    local current_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}' 2>/dev/null)
    
    if [[ -z "$current_congestion" || -z "$current_qdisc" ]]; then
        echo -e "${BOLD_RED}Error: Could not read current network settings!${NC}"
        return 1
    fi
    
    if [[ "$current_congestion" == "$TCP_CONGESTION" && "$current_qdisc" == "fq" ]]; then
        echo -e "${GREEN}BBR is active and properly configured!${NC}"
        echo -e "Congestion control: ${BOLD}$current_congestion${NC}"
        echo -e "Queue discipline: ${BOLD}$current_qdisc${NC}"
        return 0
    else
        echo -e "${BOLD_RED}BBR is not properly configured!${NC}"
        echo -e "Current congestion control: ${BOLD}$current_congestion${NC}"
        echo -e "Current queue discipline: ${BOLD}$current_qdisc${NC}"
        return 1
    fi
}
# Setup Cron Job for Auto Reset
setup_cron_job() {
    local cron_time="0 4 * * *"  # Default: 4 AM daily
    local script_path=$(readlink -f "$0")
    
    echo -e "${YELLOW}Setting up cron job for auto-reset...${NC}"
    echo -e "${CYAN}Current cron time: $cron_time${NC}"
    
    read -p "Do you want to change the schedule? (y/n): " change_schedule
    if [[ "$change_schedule" =~ ^[Yy] ]]; then
        echo -e "\n${YELLOW}Cron schedule format:${NC}"
        echo -e "Minute Hour Day Month DayOfWeek"
        echo -e "Example: 0 4 * * * (runs daily at 4 AM)"
        read -p "Enter new cron schedule: " cron_time
    fi
    
    echo "$cron_time root $script_path --reset > /dev/null 2>&1" > "$CRON_JOB_FILE"
    chmod 644 "$CRON_JOB_FILE"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${BOLD_RED}Error creating cron job!${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Cron job installed at $CRON_JOB_FILE${NC}"
    echo -e "The system will automatically reset network settings at: ${BOLD}$cron_time${NC}"
    return 0
}
# Reset Network Settings
reset_network() {
    echo -e "${YELLOW}Resetting network settings to default...${NC}"
    
    if [[ -f "$SYSCTL_BACKUP" ]]; then
        if ! cp "$SYSCTL_BACKUP" /etc/sysctl.conf; then
            echo -e "${BOLD_RED}Error restoring backup!${NC}"
            return 1
        fi
        
        if ! sysctl -p >/dev/null 2>&1; then
            echo -e "${BOLD_RED}Error applying restored settings!${NC}"
            return 1
        fi
        
        # Reset MTU to default using persistent method
        set_mtu_persistent "$NETWORK_INTERFACE" "$DEFAULT_MTU"
        CURRENT_MTU=$DEFAULT_MTU
        
        # Reset DNS to default using persistent method
        DNS_SERVERS=("1.1.1.1" "8.8.8.8")
        set_dns_persistent "${DNS_SERVERS[@]}"
        
        echo -e "${GREEN}Network settings restored from backup!${NC}"
        
        # Restart network service
        restart_network_services
        
        return 0
    else
        echo -e "${BOLD_RED}No backup found! Cannot reset network settings.${NC}"
        return 1
    fi
}
# Restart Network Services
restart_network_services() {
    echo -e "${YELLOW}Restarting network services...${NC}"
    
    case $OS in
        *Ubuntu*|*Debian*)
            systemctl restart networking 2>/dev/null || service networking restart 2>/dev/null
            ;;
        *CentOS*|*Red*Hat*|*Fedora*)
            systemctl restart network 2>/dev/null || service network restart 2>/dev/null
            ;;
        *Arch*)
            systemctl restart systemd-networkd 2>/dev/null
            ;;
        *)
            echo -e "${YELLOW}Unknown OS! Please restart network manually.${NC}"
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Network services restarted successfully.${NC}"
    else
        echo -e "${BOLD_RED}Could not restart network services. You may need to reboot.${NC}"
        return 1
    fi
}
# Configure VIP Settings
configure_vip() {
    echo -e "\n${YELLOW}Configuring VIP Optimization${NC}"
    
    read -p "Enable VIP Mode? (y/n): " choice
    if [[ "$choice" =~ ^[Yy] ]]; then
        VIP_MODE=true
        
        read -p "Enter VIP Subnet (e.g., 10.0.0.0/24): " VIP_SUBNET
        read -p "Enter VIP Gateway (e.g., 10.0.0.1): " VIP_GATEWAY
        
        echo -e "${GREEN}VIP Mode enabled with Subnet: $VIP_SUBNET, Gateway: $VIP_GATEWAY${NC}"
    else
        VIP_MODE=false
        VIP_SUBNET=""
        VIP_GATEWAY=""
        echo -e "${YELLOW}VIP Mode disabled${NC}"
    fi
    
    save_config
}
# Configure MTU
configure_mtu() {
    echo -e "\n${YELLOW}Configuring Network Interface MTU${NC}"
    
    echo -e "Current MTU: ${BOLD}$CURRENT_MTU${NC}"
    read -p "Do you want to change MTU? (y/n): " change_mtu
    
    if [[ "$change_mtu" =~ ^[Yy] ]]; then
        read -p "Enter new MTU value (recommended: 1420): " new_mtu
        
        if ! [[ "$new_mtu" =~ ^[0-9]+$ ]]; then
            echo -e "${BOLD_RED}Error: MTU must be a number!${NC}"
            return 1
        fi
        
        # Use persistent method to set MTU
        set_mtu_persistent "$NETWORK_INTERFACE" "$new_mtu"
        
        # Update current MTU variable
        CURRENT_MTU=$new_mtu
        echo -e "${GREEN}MTU successfully changed to $new_mtu!${NC}"
        
        save_config
    fi
}
# Configure DNS
configure_dns() {
    echo -e "\n${YELLOW}Configuring DNS Servers${NC}"
    
    echo -e "Current DNS: ${BOLD}$CURRENT_DNS${NC}"
    read -p "Do you want to change DNS servers? (y/n): " change_dns
    
    if [[ "$change_dns" =~ ^[Yy] ]]; then
        echo -e "\n${YELLOW}Enter DNS servers (space separated, max 3)${NC}"
        echo -e "Example: 1.1.1.1 8.8.8.8 9.9.9.9"
        read -p "New DNS servers: " new_dns
        
        # Validate IP addresses
        local valid_dns=()
        for dns in $new_dns; do
            if [[ "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                valid_dns+=("$dns")
            else
                echo -e "${BOLD_RED}Error: $dns is not a valid IP address!${NC}"
                return 1
            fi
        done
        
        if [ ${#valid_dns[@]} -eq 0 ]; then
            echo -e "${BOLD_RED}Error: No valid DNS servers provided!${NC}"
            return 1
        fi
        
        # Use persistent method to set DNS
        set_dns_persistent "${valid_dns[@]}"
        
        # Update DNS_SERVERS array and CURRENT_DNS
        DNS_SERVERS=("${valid_dns[@]}")
        CURRENT_DNS="${valid_dns[@]}"
        
        echo -e "${GREEN}DNS servers updated successfully!${NC}"
        echo -e "New DNS: ${BOLD}${DNS_SERVERS[@]}${NC}"
        
        save_config
    fi
}
# Save Configuration
save_config() {
    echo -e "${YELLOW}Saving configuration to $CONFIG_FILE...${NC}"
    
    cat > "$CONFIG_FILE" <<EOL
# BBR VIP Optimizer Configuration
ENABLE_BBR=$ENABLE_BBR
ENABLE_FASTOPEN=$ENABLE_FASTOPEN
TCP_CONGESTION="$TCP_CONGESTION"
TCP_FASTOPEN=$TCP_FASTOPEN
VIP_MODE=$VIP_MODE
VIP_SUBNET="$VIP_SUBNET"
VIP_GATEWAY="$VIP_GATEWAY"
MTU=$CURRENT_MTU
DNS_SERVERS=(${DNS_SERVERS[@]})
EOL
    echo -e "${GREEN}Configuration saved successfully!${NC}"
}
# Network Interface Configuration
configure_interface() {
    echo -e "\n${YELLOW}Configuring network interface: $NETWORK_INTERFACE${NC}"
    
    # Enable BBR for the specific interface
    if ! tc qdisc add dev $NETWORK_INTERFACE root fq 2>/dev/null; then
        echo -e "${YELLOW}Queue discipline already configured or failed to set.${NC}"
    fi
    
    # Apply additional interface-specific settings
    ethtool -K $NETWORK_INTERFACE tso on gso on gro on 2>/dev/null
    ethtool -C $NETWORK_INTERFACE rx-usecs 30 2>/dev/null
    
    # Set MTU using persistent method
    set_mtu_persistent "$NETWORK_INTERFACE" "$CURRENT_MTU"
    
    echo -e "${GREEN}Interface configuration applied to $NETWORK_INTERFACE${NC}"
}
# Test Network Speed
test_speed() {
    echo -e "\n${YELLOW}Running network speed test...${NC}"
    
    if ! command -v speedtest-cli &> /dev/null; then
        echo -e "${YELLOW}Installing speedtest-cli...${NC}"
        if pip install speedtest-cli 2>/dev/null || apt-get install -y speedtest-cli 2>/dev/null || \
           yum install -y speedtest-cli 2>/dev/null || dnf install -y speedtest-cli 2>/dev/null; then
            echo -e "${GREEN}speedtest-cli installed successfully!${NC}"
        else
            echo -e "${BOLD_RED}Could not install speedtest-cli. Please install it manually.${NC}"
            return 1
        fi
    fi
    
    echo -e "${CYAN}Testing download and upload speed...${NC}"
    speedtest-cli --simple
    
    echo -e "\n${CYAN}Testing latency to 1.1.1.1...${NC}"
    ping -c 5 1.1.1.1 | grep -A1 "statistics"
}
# Show Current Settings
show_settings() {
    echo -e "\n${YELLOW}Current Configuration:${NC}"
    echo -e "BBR Enabled: ${BOLD}$ENABLE_BBR${NC}"
    echo -e "TCP Fast Open: ${BOLD}$TCP_FASTOPEN${NC}"
    echo -e "VIP Mode: ${BOLD}$VIP_MODE${NC}"
    echo -e "MTU: ${BOLD}$CURRENT_MTU${NC}"
    echo -e "DNS Servers: ${BOLD}${DNS_SERVERS[@]}${NC}"
    
    if [ "$VIP_MODE" = true ]; then
        echo -e "VIP Subnet: ${BOLD}$VIP_SUBNET${NC}"
        echo -e "VIP Gateway: ${BOLD}$VIP_GATEWAY${NC}"
    fi
    
    echo -e "\n${YELLOW}Current Kernel Parameters:${NC}"
    sysctl -a 2>/dev/null | grep -E "net.core.default_qdisc|net.ipv4.tcp_congestion_control|net.ipv4.tcp_fastopen"
    
    echo -e "\n${YELLOW}Interface Settings:${NC}"
    ethtool -k $NETWORK_INTERFACE 2>/dev/null | grep -E "tcp-segmentation-offload:|generic-segmentation-offload:|generic-receive-offload:"
    echo -e "Current Interface MTU: ${BOLD}$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null)${NC}"
}
# Show System Information
show_system_info() {
    echo -e "\n${YELLOW}System Information:${NC}"
    echo -e "Hostname: ${BOLD}$(hostname)${NC}"
    echo -e "Uptime: ${BOLD}$(uptime -p)${NC}"
    echo -e "OS: ${BOLD}$OS $VER${NC}"
    echo -e "Kernel: ${BOLD}$(uname -r)${NC}"
    echo -e "CPU: ${BOLD}$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')${NC}"
    echo -e "Memory: ${BOLD}$(free -h | awk '/Mem/{print $3"/"$2}') used${NC}"
    
    echo -e "\n${YELLOW}Network Information:${NC}"
    echo -e "Public IP: ${BOLD}$(curl -s ifconfig.me)${NC}"
    echo -e "Local IP: ${BOLD}$(hostname -I | awk '{print $1}')${NC}"
    echo -e "Gateway: ${BOLD}$(ip route | grep default | awk '{print $3}')${NC}"
}
# Main Menu
show_menu() {
    while true; do
        show_header
        echo -e "\n${BOLD}Main Menu:${NC}"
        echo -e "${CYAN}1) Apply Full Optimization${NC}"
        echo -e "${CYAN}2) Verify Current Configuration${NC}"
        echo -e "${CYAN}3) Reset Network Settings${NC}"
        echo -e "${CYAN}4) Install Auto-Reset Cron Job${NC}"
        echo -e "${PURPLE}5) Configure Network Interface${NC}"
        echo -e "${PURPLE}6) Configure VIP Settings${NC}"
        echo -e "${PURPLE}7) Configure MTU${NC}"
        echo -e "${PURPLE}8) Configure DNS${NC}"
        echo -e "${GREEN}9) Show Current Settings${NC}"
        echo -e "${GREEN}10) Test Network Speed${NC}"
        echo -e "${GREEN}11) Show System Info${NC}"
        echo -e "${BLUE}12) Save Configuration${NC}"
        echo -e "${RED}13) Reboot Server${NC}"
        echo -e "${BOLD_RED}14) Exit${NC}"
        
        read -p "Please enter your choice [1-14]: " choice
        
        case $choice in
            1)
                backup_sysctl
                apply_kernel_params
                configure_interface
                verify_bbr
                ;;
            2)
                verify_bbr
                ;;
            3)
                reset_network
                ;;
            4)
                setup_cron_job
                ;;
            5)
                configure_interface
                ;;
            6)
                configure_vip
                ;;
            7)
                configure_mtu
                ;;
            8)
                configure_dns
                ;;
            9)
                show_settings
                ;;
            10)
                test_speed
                ;;
            11)
                show_system_info
                ;;
            12)
                save_config
                ;;
            13)
                echo -e "${YELLOW}Preparing to reboot server...${NC}"
                save_config
                echo -e "${RED}Server will now reboot...${NC}"
                sleep 3
                reboot
                ;;
            14)
                echo -e "${GREEN}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${BOLD_RED}Invalid option!${NC}"
                ;;
        esac
        
        read -p "Press [Enter] to return to main menu..."
    done
}
# Main Execution
main() {
    check_root
    detect_distro
    load_config
    show_menu
}
# Handle command line arguments
case "$1" in
    "--reset")
        reset_network
        exit $?
        ;;
    *)
        main
        ;;
esac
