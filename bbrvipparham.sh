#!/bin/bash
# BBR2 Ultra Optimizer - Parham Edition
# Compatible with all Ubuntu versions & architectures

CONFIG_FILE="/etc/parham_bbr_config"
DNS_FILE="/etc/resolv.conf"
SYSCTL_FILE="/etc/sysctl.conf"
MTU_DEFAULT=1420
DNS_DEFAULT="1.1.1.1"

# Detect main network interface
NET_IFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

save_config() {
    echo "NET_IFACE=$NET_IFACE" > "$CONFIG_FILE"
    echo "DNS=$(cat $DNS_FILE | grep nameserver | awk '{print $2}')" >> "$CONFIG_FILE"
    echo "MTU=$(ip link show $NET_IFACE | grep -oP '(?<=mtu )\d+')" >> "$CONFIG_FILE"
}

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

apply_sysctl_settings() {
    cat <<EOF >> $SYSCTL_FILE

# BBR2 Optimized Settings - Parham Edition
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr2
net.ipv4.tcp_fastopen=3
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_mtu_probing=1
EOF
    sysctl -p
}

install_bbr2() {
    echo -e "${GREEN}Installing BBR2 with full optimization...${RESET}"
    apt update -y && apt install -y wget curl
    modprobe tcp_bbr2 || true
    apply_sysctl_settings
    change_dns "$DNS_DEFAULT"
    change_mtu "$MTU_DEFAULT"
    save_config
    echo -e "${GREEN}BBR2 installation completed!${RESET}"
}

uninstall_bbr2() {
    echo -e "${RED}Removing BBR2 and restoring defaults...${RESET}"
    sed -i '/# BBR2 Optimized Settings - Parham Edition/,+9d' $SYSCTL_FILE
    sysctl -p
    echo "nameserver 8.8.8.8" > "$DNS_FILE"
    ip link set dev $NET_IFACE mtu 1500
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}All changes reverted.${RESET}"
}

change_dns() {
    local new_dns=$1
    if [ -z "$new_dns" ]; then
        read -p "Enter new DNS: " new_dns
    fi
    echo "nameserver $new_dns" > "$DNS_FILE"
    echo -e "${GREEN}DNS changed to $new_dns${RESET}"
    save_config
}

change_mtu() {
    local new_mtu=$1
    if [ -z "$new_mtu" ]; then
        read -p "Enter new MTU: " new_mtu
    fi
    ip link set dev $NET_IFACE mtu $new_mtu
    echo -e "${GREEN}MTU changed to $new_mtu${RESET}"
    save_config
}

show_status() {
    echo -e "${YELLOW}--- Current Settings ---${RESET}"
    echo "Interface: $NET_IFACE"
    echo "MTU: $(ip link show $NET_IFACE | grep -oP '(?<=mtu )\d+')"
    echo "DNS: $(grep nameserver $DNS_FILE | awk '{print $2}')"
    sysctl net.ipv4.tcp_congestion_control
}

menu() {
    clear
    echo -e "${GREEN}BBR2 Ultra Optimizer - Parham Edition${RESET}"
    echo "1) Install Optimized BBR2"
    echo "2) Uninstall & Revert Changes"
    echo "3) Change DNS Manually"
    echo "4) Change MTU Manually"
    echo "5) Show Current Status"
    echo "6) Reboot System"
    echo "0) Exit"
    read -p "Choose an option: " choice
    case $choice in
        1) install_bbr2 ;;
        2) uninstall_bbr2 ;;
        3) change_dns ;;
        4) change_mtu ;;
        5) show_status ;;
        6) reboot ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
    read -p "Press Enter to continue..."
    menu
}

load_config
menu
