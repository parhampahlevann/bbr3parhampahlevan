#!/bin/bash

# Global Configuration
SCRIPT_NAME="BBR VIP Optimizer Pro"
SCRIPT_VERSION="4.2"  # نسخه آپدیت‌شده
AUTHOR="Parham Pahlevan"
CONFIG_FILE="/etc/bbr_vip.conf"
LOG_FILE="/var/log/bbr_vip.log"
SYSCTL_BACKUP="/etc/sysctl.conf.bak"
CRON_JOB_FILE="/etc/cron.d/bbr_vip_autoresst"
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
VIP_MODE=false
VIP_SUBNET=""
VIP_GATEWAY=""
DEFAULT_MTU=1420
CURRENT_MTU=$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null || echo $DEFAULT_MTU)
DNS_SERVERS=("1.1.1.1")
CURRENT_DNS=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
OS=""
VER=""

# Initialize logging (create log file if missing)
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
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
    echo -e "${BLUE}${BOLD}╔═════════════════════════════════════════════════════════╗"
    echo -e "║   ${SCRIPT_NAME} ${SCRIPT_VERSION} - ${AUTHOR}              ║"
    echo -e "╚═════════════════════════════════════════════════════════╝${NC}"
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

# Helper: test connectivity after MTU change
_test_connectivity() {
    # try gateway first, else 1.1.1.1
    local gw
    gw=$(ip route | awk '/default/ {print $3; exit}')
    local target
    if [[ -n "$gw" ]]; then
        target="$gw"
    else
        target="1.1.1.1"
    fi

    # give kernel a moment to settle
    sleep 2

    # ping for a short time (2 packets, wait 3s each)
    if ping -c 2 -W 3 "$target" >/dev/null 2>&1; then
        return 0
    fi

    # fallback: try 1.1.1.1 if we tested gateway and failed
    if [[ "$target" != "1.1.1.1" ]]; then
        if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# Configure MTU Permanently (Safe Mode)
configure_mtu_permanent() {
    echo -e "${YELLOW}Attempting to set permanent MTU $CURRENT_MTU on $NETWORK_INTERFACE...${NC}"

    # read old mtu for rollback
    local OLD_MTU
    OLD_MTU=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo "$DEFAULT_MTU")

    # set temporary MTU
    if ! ip link set dev "$NETWORK_INTERFACE" mtu "$CURRENT_MTU" 2>>"$LOG_FILE"; then
        echo -e "${BOLD_RED}Error: could not set temporary MTU on $NETWORK_INTERFACE${NC}"
        return 1
    fi

    echo -e "${CYAN}Temporary MTU set to $CURRENT_MTU — testing connectivity...${NC}"

    # test connectivity; if fails, rollback
    if ! _test_connectivity; then
        echo -e "${BOLD_RED}Connectivity test FAILED after temporary MTU change. Rolling back to $OLD_MTU...${NC}"
        ip link set dev "$NETWORK_INTERFACE" mtu "$OLD_MTU" 2>>"$LOG_FILE"
        CURRENT_MTU=$OLD_MTU
        return 1
    fi

    echo -e "${GREEN}Connectivity OK with MTU $CURRENT_MTU — applying permanent configuration...${NC}"

    # Apply permanent configuration based on network manager
    # 1) Netplan
    if [[ -d /etc/netplan ]] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
        NETPLAN_FILE=$(ls /etc/netplan/*.yaml | head -n1)

        # If interface name exists in file, try to set its mtu, else add simple ethernets block
        if grep -qE "^[[:space:]]*$NETWORK_INTERFACE:" "$NETPLAN_FILE" >/dev/null 2>&1; then
            # interface entry exists; try to insert/replace mtu within that block
            # naive but practical approach: if 'mtu:' exists anywhere, replace first occurrence under that iface; else insert after iface line
            if grep -A3 -n "^[[:space:]]*$NETWORK_INTERFACE:" "$NETPLAN_FILE" | grep -q "mtu:"; then
                sed -i "/^[[:space:]]*$NETWORK_INTERFACE:/, /^$/ s/mtu: .*/mtu: $CURRENT_MTU/" "$NETPLAN_FILE"
            else
                sed -i "/^[[:space:]]*$NETWORK_INTERFACE:/a\      mtu: $CURRENT_MTU" "$NETPLAN_FILE"
            fi
        else
            # try to add under ethernets if present
            if grep -q "^[[:space:]]*ethernets:" "$NETPLAN_FILE"; then
                # append a minimal entry for the interface
                awk -v iface="$NETWORK_INTERFACE" -v mtu="$CURRENT_MTU" '
                    BEGIN {added=0}
                    /^([[:space:]]*)ethernets:/ && added==0 {
                        print; getline; print; print "      "iface":\n        dhcp4: true\n        mtu: "mtu; added=1; next
                    }
                    {print}
                ' "$NETPLAN_FILE" > "$NETPLAN_FILE.tmp" && mv "$NETPLAN_FILE.tmp" "$NETPLAN_FILE"
            else
                # fallback: append full network section
                cat >> "$NETPLAN_FILE" <<EOF

network:
  version: 2
  ethernets:
    $NETWORK_INTERFACE:
      dhcp4: true
      mtu: $CURRENT_MTU
EOF
            fi
        fi

        if netplan apply 2>>"$LOG_FILE"; then
            echo -e "${GREEN}Netplan updated and applied.${NC}"
            return 0
        else
            echo -e "${YELLOW}Warning: netplan apply failed — continuing to try other methods (if available).${NC}"
        fi
    fi

    # 2) NetworkManager (nmcli)
    if command -v nmcli >/dev/null 2>&1 && systemctl is-active NetworkManager >/dev/null 2>&1; then
        CONNECTION=$(nmcli -t -f NAME,DEVICE connection show | grep "$NETWORK_INTERFACE" | cut -d: -f1 | head -n1)
        if [[ -n "$CONNECTION" ]]; then
            if nmcli connection modify "$CONNECTION" 802-3-ethernet.mtu "$CURRENT_MTU" 2>>"$LOG_FILE"; then
                nmcli connection up "$CONNECTION" 2>>"$LOG_FILE" || true
                echo -e "${GREEN}NetworkManager connection modified.${NC}"
                return 0
            else
                echo -e "${YELLOW}Warning: nmcli modify failed.${NC}"
            fi
        else
            echo -e "${YELLOW}No NetworkManager connection matching $NETWORK_INTERFACE found.${NC}"
        fi
    fi

    # 3) systemd-networkd
    if systemctl is-active systemd-networkd >/dev/null 2>&1; then
        mkdir -p /etc/systemd/network
        cat <<EOF > /etc/systemd/network/20-"$NETWORK_INTERFACE".network
[Match]
Name=$NETWORK_INTERFACE

[Link]
MTUBytes=$CURRENT_MTU
EOF
        if systemctl restart systemd-networkd 2>>"$LOG_FILE"; then
            echo -e "${GREEN}systemd-networkd configured and restarted.${NC}"
            return 0
        else
            echo -e "${YELLOW}Warning: restarting systemd-networkd failed.${NC}"
        fi
    fi

    # 4) CentOS/RHEL ifcfg
    if [[ -d /etc/sysconfig/network-scripts ]]; then
        IFCFG_FILE="/etc/sysconfig/network-scripts/ifcfg-$NETWORK_INTERFACE"
        if [[ -f "$IFCFG_FILE" ]]; then
            if grep -q "^MTU=" "$IFCFG_FILE"; then
                sed -i "s/^MTU=.*/MTU=$CURRENT_MTU/" "$IFCFG_FILE"
            else
                echo "MTU=$CURRENT_MTU" >> "$IFCFG_FILE"
            fi
            systemctl restart network 2>>"$LOG_FILE" || nmcli connection reload 2>>"$LOG_FILE" || true
            echo -e "${GREEN}ifcfg file updated.${NC}"
            return 0
        else
            # create a basic ifcfg file as fallback
            cat > "$IFCFG_FILE" <<EOF
DEVICE=$NETWORK_INTERFACE
BOOTPROTO=dhcp
ONBOOT=yes
MTU=$CURRENT_MTU
EOF
            chmod 600 "$IFCFG_FILE"
            systemctl restart network 2>>"$LOG_FILE" || true
            echo -e "${GREEN}Created ifcfg file as fallback.${NC}"
            return 0
        fi
    fi

    # 5) /etc/network/interfaces (Debian legacy)
    if [[ -f /etc/network/interfaces ]]; then
        if grep -q "iface $NETWORK_INTERFACE" /etc/network/interfaces; then
            # remove any existing mtu line in the iface block, then insert
            sed -i "/iface $NETWORK_INTERFACE/,/^\s*$/ {/mtu /d}" /etc/network/interfaces
            sed -i "/iface $NETWORK_INTERFACE/a\    mtu $CURRENT_MTU" /etc/network/interfaces
        else
            echo -e "\nauto $NETWORK_INTERFACE\niface $NETWORK_INTERFACE inet dhcp\n    mtu $CURRENT_MTU" >> /etc/network/interfaces
        fi
        systemctl restart networking 2>>"$LOG_FILE" || service networking restart 2>>"$LOG_FILE" || true
        echo -e "${GREEN}/etc/network/interfaces updated.${NC}"
        return 0
    fi

    # If reached here, we couldn't detect a supported config — but the temporary change works.
    echo -e "${YELLOW}Warning: could not write permanent config to known network managers. Temporary MTU applied successfully.${NC}"
    return 0
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

        # Apply default MTU (safe)
        ip link set dev "$NETWORK_INTERFACE" mtu "$DEFAULT_MTU" 2>>"$LOG_FILE" || true
        CURRENT_MTU=$DEFAULT_MTU
        configure_mtu_permanent || true
        update_dns
        save_config
    fi
}

# Update DNS Configuration
update_dns() {
    echo "# Generated by $SCRIPT_NAME" > /etc/resolv.conf
    for dns in "${DNS_SERVERS[@]}"; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    CURRENT_DNS="${DNS_SERVERS[*]}"
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

    local temp_file
    temp_file=$(mktemp)

    while IFS= read -r line; do
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

    {
        echo -e "\n# Added by $SCRIPT_NAME"
        for param in "${DEFAULT_KERNEL_PARAMS[@]}"; do
            echo "$param"
        done

        if [ "$VIP_MODE" = true ]; then
            echo -e "\n# VIP Optimization Parameters"
            for param in "${VIP_KERNEL_PARAMS[@]}"; do
                echo "$param"
            done
        fi
    } >> "$temp_file"

    mv "$temp_file" /etc/sysctl.conf

    if ! sysctl -p >>"$LOG_FILE" 2>&1; then
        echo -e "${BOLD_RED}Error applying sysctl settings!${NC}"
        return 1
    fi

    echo -e "${GREEN}Kernel parameters applied successfully!${NC}"
    return 0
}

# Verify BBR Status
verify_bbr() {
    echo -e "${YELLOW}Verifying BBR status...${NC}"

    local current_congestion
    current_congestion=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null)
    local current_qdisc
    current_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}' 2>/dev/null)

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
    local script_path
    script_path=$(readlink -f "$0")

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

        if ! sysctl -p >>"$LOG_FILE" 2>&1; then
            echo -e "${BOLD_RED}Error applying restored settings!${NC}"
            return 1
        fi

        # Reset MTU to default (safe)
        local old_mtu
        old_mtu=$(cat /sys/class/net/"$NETWORK_INTERFACE"/mtu 2>/dev/null || echo "$DEFAULT_MTU")
        CURRENT_MTU=$DEFAULT_MTU
        ip link set dev "$NETWORK_INTERFACE" mtu "$CURRENT_MTU" 2>>"$LOG_FILE" || true
        configure_mtu_permanent || {
            echo -e "${YELLOW}Warning: could not persist default MTU, temporary set only.${NC}"
        }
        update_dns

        echo -e "${GREEN}Network settings restored from backup!${NC}"
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
            systemctl restart networking 2>>"$LOG_FILE" || service networking restart 2>>"$LOG_FILE"
            ;;
        *CentOS*|*Red*Hat*|*Fedora*)
            systemctl restart network 2>>"$LOG_FILE" || service network restart 2>>"$LOG_FILE"
            ;;
        *Arch*)
            systemctl restart systemd-networkd 2>>"$LOG_FILE"
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

        echo -e "${YELLOW}Setting temporary MTU to $new_mtu for $NETWORK_INTERFACE...${NC}"
        if ! ip link set dev "$NETWORK_INTERFACE" mtu "$new_mtu" 2>>"$LOG_FILE"; then
            echo -e "${BOLD_RED}Error setting temporary MTU!${NC}"
            return 1
        fi

        # update CURRENT_MTU and try to persist safely
        CURRENT_MTU=$new_mtu
        if configure_mtu_permanent; then
            echo -e "${GREEN}MTU successfully changed to $new_mtu!${NC}"
            save_config
        else
            echo -e "${BOLD_RED}MTU change aborted to prevent network loss. Current MTU restored.${NC}"
        fi
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

        DNS_SERVERS=("${valid_dns[@]}")
        update_dns
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

# Test Network Speed
test_speed() {
    echo -e "\n${YELLOW}Running network speed test...${NC}"

    if ! command -v speedtest-cli &> /dev/null; then
        echo -e "${YELLOW}Installing speedtest-cli...${NC}"
        if pip install speedtest-cli 2>>"$LOG_FILE" || apt-get install -y speedtest-cli 2>>"$LOG_FILE" || \
           yum install -y speedtest-cli 2>>"$LOG_FILE" || dnf install -y speedtest-cli 2>>"$LOG_FILE"; then
            echo -e "${GREEN}speedtest-cli installed successfully!${NC}"
        else
            echo -e "${BOLD_RED}Could not install speedtest-cli. Please install it manually.${NC}"
            return 1
        fi
    fi

    echo -e "${CYAN}Testing download and upload speed...${NC}"
    speedtest-cli --simple >>"$LOG_FILE" 2>&1

    echo -e "\n${CYAN}Testing latency to 1.1.1.1...${NC}"
    ping -c 5 1.1.1.1 | grep -A1 "statistics" | tee -a "$LOG_FILE"
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
    sysctl -a 2>/dev/null | grep -E "net.core.default_qdisc|net.ipv4.tcp_congestion_control|net.ipv4.tcp_fastopen" | tee -a "$LOG_FILE"

    echo -e "\n${YELLOW}Interface Settings:${NC}"
    echo -e "Current Interface MTU: ${BOLD}$(cat /sys/class/net/$NETWORK_INTERFACE/mtu 2>/dev/null)${NC}"
}

# Uninstall All Changes
uninstall_all() {
    echo -e "\n${BOLD_RED}Uninstalling all changes...${NC}"

    if [[ -f "$SYSCTL_BACKUP" ]]; then
        cp "$SYSCTL_BACKUP" /etc/sysctl.conf
        sysctl -p >>"$LOG_FILE" 2>&1
        echo -e "${GREEN}Restored original sysctl settings${NC}"
    fi

    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}Removed configuration file${NC}"

    rm -f "$CRON_JOB_FILE"
    echo -e "${GREEN}Removed cron job${NC}"

    ip link set dev "$NETWORK_INTERFACE" mtu 1500 2>>"$LOG_FILE" || true
    CURRENT_MTU=1500
    configure_mtu_permanent || true
    echo -e "${GREEN}Reset MTU to default 1500 (if possible)${NC}"

    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf
    echo -e "${GREEN}Reset DNS to Google DNS${NC}"

    echo -e "\n${GREEN}Uninstallation complete!${NC}"
    read -p "Press [Enter] to continue..."
}

# Main Menu
show_menu() {
    while true; do
        show_header
        echo -e "\n${BOLD}Main Menu:${NC}"
        echo -e "${CYAN}1) Apply Full Optimization${NC}"
        echo -e "${CYAN}3) Reset Network Settings${NC}"
        echo -e "${CYAN}4) Install Auto-Reset Cron Job${NC}"
        echo -e "${PURPLE}6) Configure VIP Settings${NC}"
        echo -e "${PURPLE}7) Configure MTU${NC}"
        echo -e "${PURPLE}8) Configure DNS${NC}"
        echo -e "${GREEN}9) Show Current Settings${NC}"
        echo -e "${GREEN}10) Test Network Speed${NC}"
        echo -e "${BLUE}12) Save Configuration${NC}"
        echo -e "${RED}13) Reboot Server${NC}"
        echo -e "${BOLD_RED}14) Uninstall (Remove All Changes)${NC}"
        echo -e "${BOLD_RED}15) Exit${NC}"

        read -p "Please enter your choice [1-15]: " choice

        case $choice in
            1)
                backup_sysctl
                apply_kernel_params
                verify_bbr
                ;;
            3)
                reset_network
                ;;
            4)
                setup_cron_job
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
                uninstall_all
                ;;
            15)
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
