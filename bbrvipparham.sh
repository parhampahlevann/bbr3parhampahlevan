#!/bin/bash

# Global Configuration
SCRIPT_NAME="BBR VIP Optimizer"
SCRIPT_VERSION="3.1"
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
SYSCTL_BACKUP="/etc/sysctl.conf.bak"
CRON_JOB_FILE="/etc/cron.d/bbr_vip_autoreset"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
VIP_MODE=false
VIP_SUBNET=""
VIP_GATEWAY=""
DEFAULT_DNS_SERVERS="8.8.8.8 8.8.4.4 1.1.1.1"

# Initialize logging
exec > >(tee -a "$LOG_FILE") 2>&1

# Color Codes
RED='\033[0;31m'
BOLD_RED='\033[1;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Header Display
show_header() {
    clear
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════╗"
    echo -e "║   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}          ║"
    echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Network Interface Detected: ${BOLD}$NETWORK_INTERFACE${NC}"
    echo -e "${YELLOW}VIP Mode: ${BOLD}$([ "$VIP_MODE" = true ] && echo "Enabled" || echo "Disabled")${NC}\n"
}

# Check Root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${BOLD_RED}Error: This script must be run as root!${NC}"
        exit 1
    fi
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
    fi
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
    
    # Apply default parameters
    for param in "${DEFAULT_KERNEL_PARAMS[@]}"; do
        key=$(echo "$param" | cut -d= -f1)
        value=$(echo "$param" | cut -d= -f2)
        
        if grep -q "^$key" /etc/sysctl.conf; then
            sed -i "s/^$key.*/$param/" /etc/sysctl.conf
        else
            echo "$param" >> /etc/sysctl.conf
        fi
    done
    
    # Apply VIP parameters if enabled
    if [ "$VIP_MODE" = true ]; then
        echo -e "${YELLOW}Applying VIP optimization parameters...${NC}"
        for param in "${VIP_KERNEL_PARAMS[@]}"; do
            key=$(echo "$param" | cut -d= -f1)
            value=$(echo "$param" | cut -d= -f2)
            
            if grep -q "^$key" /etc/sysctl.conf; then
                sed -i "s/^$key.*/$param/" /etc/sysctl.conf
            else
                echo "$param" >> /etc/sysctl.conf
            fi
        done
    fi
    
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
    
    echo "$cron_time root $script_path --reset > /dev/null 2>&1" > "$CRON_JOB_FILE"
    chmod 644 "$CRON_JOB_FILE"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${BOLD_RED}Error creating cron job!${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Cron job installed at $CRON_JOB_FILE${NC}"
    echo -e "The system will automatically reset network settings daily at 4 AM"
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
    
    if systemctl restart networking 2>/dev/null || \
       systemctl restart network 2>/dev/null || \
       service networking restart 2>/dev/null || \
       service network restart 2>/dev/null; then
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
        echo -e "${YELLOW}VIP Mode disabled${NC}"
    fi
    
    # Save to config file
    save_config
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
    
    echo -e "${GREEN}Interface configuration applied to $NETWORK_INTERFACE${NC}"
}

# Configure DNS on all interfaces
configure_dns() {
    echo -e "\n${YELLOW}Configuring DNS on all interfaces...${NC}"
    
    read -p "Enter DNS servers (space separated, default: $DEFAULT_DNS_SERVERS): " DNS_SERVERS
    DNS_SERVERS=${DNS_SERVERS:-$DEFAULT_DNS_SERVERS}
    
    local INTERFACES=$(ls /sys/class/net/ | grep -v lo)

    for IFACE in $INTERFACES; do
        echo -e "${YELLOW}Setting DNS for interface $IFACE...${NC}"
        
        # برای سیستم‌های با netplan (Ubuntu 18.04 به بعد)
        if [ -d /etc/netplan ]; then
            local NETPLAN_FILE=$(ls /etc/netplan/*.yaml | head -n 1)
            if [ -f "$NETPLAN_FILE" ]; then
                if grep -q "$IFACE:" "$NETPLAN_FILE"; then
                    if grep -q "nameservers:" "$NETPLAN_FILE"; then
                        sed -i "/$IFACE:/,/^[^ ]/ {/nameservers:/!b; /addresses:/! {N; /addresses:/!b}; s/addresses:.*/addresses: [$DNS_SERVERS]/}" "$NETPLAN_FILE"
                    else
                        sed -i "/$IFACE:/a \    nameservers:\n      addresses: [$DNS_SERVERS]" "$NETPLAN_FILE"
                    fi
                    netplan apply
                fi
            fi
        fi
        
        # برای سیستم‌های با NetworkManager
        if command -v nmcli &> /dev/null; then
            nmcli con mod "$IFACE" ipv4.dns "$DNS_SERVERS"
            nmcli con up "$IFACE"
        fi
        
        # برای سیستم‌های قدیمی با resolv.conf
        if [ -f /etc/resolv.conf ]; then
            chattr -i /etc/resolv.conf 2>/dev/null
            echo -e "# Generated by $SCRIPT_NAME\nnameserver $DNS_SERVERS" > /etc/resolv.conf
            chattr +i /etc/resolv.conf 2>/dev/null
        fi
    done
    
    echo -e "${GREEN}DNS configuration applied to all interfaces!${NC}"
}

# Add system reboot option
add_reboot_option() {
    echo -e "\n${YELLOW}Adding reboot option to the system...${NC}"
    
    # برای سیستم‌های با systemd
    if command -v systemctl &> /dev/null; then
        cat << EOF > /etc/systemd/system/reboot-me.service
[Unit]
Description=Reboot System

[Service]
Type=oneshot
ExecStart=/bin/bash -c "sleep 5 && /sbin/reboot"

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable reboot-me.service
        echo -e "${GREEN}Reboot service created and enabled.${NC}"
        echo -e "Use ${BOLD}systemctl start reboot-me${NC} to reboot the system."
    fi

    # برای سیستم‌های قدیمی
    if [ -f /etc/inittab ]; then
        if ! grep -q "reboot:12345:respawn:/sbin/reboot" /etc/inittab; then
            echo "reboot:12345:respawn:/sbin/reboot" >> /etc/inittab
            echo -e "${GREEN}Reboot option added to inittab.${NC}"
            echo -e "Use ${BOLD}init 6${NC} to reboot the system."
        else
            echo -e "${YELLOW}Reboot option already exists in inittab.${NC}"
        fi
    fi
    
    echo -e "\n${GREEN}Reboot options successfully configured!${NC}"
}

# Show Current Settings
show_settings() {
    echo -e "\n${YELLOW}Current Configuration:${NC}"
    echo -e "BBR Enabled: ${BOLD}$ENABLE_BBR${NC}"
    echo -e "TCP Fast Open: ${BOLD}$TCP_FASTOPEN${NC}"
    echo -e "VIP Mode: ${BOLD}$VIP_MODE${NC}"
    
    if [ "$VIP_MODE" = true ]; then
        echo -e "VIP Subnet: ${BOLD}$VIP_SUBNET${NC}"
        echo -e "VIP Gateway: ${BOLD}$VIP_GATEWAY${NC}"
    fi
    
    echo -e "\n${YELLOW}Current Kernel Parameters:${NC}"
    sysctl -a 2>/dev/null | grep -E "net.core.default_qdisc|net.ipv4.tcp_congestion_control|net.ipv4.tcp_fastopen"
    
    echo -e "\n${YELLOW}Interface Settings:${NC}"
    ethtool -k $NETWORK_INTERFACE 2>/dev/null | grep -E "tcp-segmentation-offload:|generic-segmentation-offload:|generic-receive-offload:"
    
    echo -e "\n${YELLOW}Current DNS Settings:${NC}"
    cat /etc/resolv.conf 2>/dev/null | grep -v "^#"
}

# Main Menu
show_menu() {
    while true; do
        show_header
        echo -e "\n${BOLD}Main Menu:${NC}"
        echo -e "1) Apply Full Optimization (BBR + VIP + Interface)"
        echo -e "2) Verify Current Configuration"
        echo -e "3) Reset Network Settings"
        echo -e "4) Install Auto-Reset Cron Job"
        echo -e "5) Configure Network Interface"
        echo -e "6) Configure VIP Settings"
        echo -e "7) Configure DNS on all interfaces"
        echo -e "8) Add System Reboot Option"
        echo -e "9) Show Current Settings"
        echo -e "10) Save Configuration"
        echo -e "11) Exit"
        
        read -p "Please enter your choice [1-11]: " choice
        
        case $choice in
            1)
                backup_sysctl
                apply_kernel_params
                configure_interface
                configure_dns
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
                configure_dns
                ;;
            8)
                add_reboot_option
                ;;
            9)
                show_settings
                ;;
            10)
                save_config
                ;;
            11)
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
    load_config
    show_menu
}

# Handle command line arguments
case "$1" in
    "--reset")
        reset_network
        exit $?
        ;;
    "--dns")
        configure_dns
        exit $?
        ;;
    "--reboot-option")
        add_reboot_option
        exit $?
        ;;
    *)
        main
        ;;
esac
