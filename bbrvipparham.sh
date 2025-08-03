#!/bin/bash

# Ultimate Manual TCP Optimizer v4.0
# Customizable Network Optimization for Ubuntu
# Created by Network Experts

# Configuration
CONFIG_FILE="/etc/sysctl.d/99-custom-network.conf"
GRUB_FILE="/etc/default/grub"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Status check
check_status() {
    echo -e "\n${YELLOW}=== Current Network Settings ===${NC}"
    echo "TCP Algorithm: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "Queue Discipline: $(sysctl -n net.core.default_qdisc)"
    echo "TCP Fast Open: $(sysctl -n net.ipv4.tcp_fastopen)"
    echo "Buffer Sizes:"
    sysctl -n net.core.rmem_max net.core.wmem_max
    echo -e "\n"
}

# Basic optimizations (safe for most connections)
basic_tcp_optimize() {
    cat > "$CONFIG_FILE" <<'EOF'
# Basic TCP Optimizations (Safe)
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_slow_start_after_idle=0

# Moderate buffer sizes
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem=4096 87380 4194304
net.ipv4.tcp_wmem=4096 65536 4194304

# Connection management
net.ipv4.tcp_max_syn_backlog=4096
net.core.somaxconn=8192
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_tw_reuse=1
EOF

    sysctl --system
    echo -e "${GREEN}Basic TCP optimizations applied${NC}"
}

# Advanced optimizations (for high-speed connections)
advanced_tcp_optimize() {
    cat > "$CONFIG_FILE" <<'EOF'
# Advanced TCP Optimizations
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_workaround_signed_windows=1
net.ipv4.tcp_slow_start_after_idle=0

# Larger buffers (for high-speed networks)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# Advanced connection management
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=16384
net.ipv4.tcp_max_tw_buckets=4000000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
EOF

    sysctl --system
    echo -e "${GREEN}Advanced TCP optimizations applied${NC}"
}

# Enable BBR
enable_bbr() {
    cat >> "$CONFIG_FILE" <<'EOF'
# BBR Congestion Control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system
    echo -e "${GREEN}BBR enabled${NC}"
}

# Enable BBR2 (if available)
enable_bbr2() {
    cat >> "$CONFIG_FILE" <<'EOF'
# BBR2 Congestion Control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr2
EOF

    sysctl --system
    echo -e "${GREEN}BBR2 enabled${NC}"
}

# Enable Cubic (default)
enable_cubic() {
    cat >> "$CONFIG_FILE" <<'EOF'
# Cubic Congestion Control
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=cubic
EOF

    sysctl --system
    echo -e "${GREEN}Cubic (default) enabled${NC}"
}

# Reset all settings
reset_settings() {
    rm -f "$CONFIG_FILE"
    sysctl --system
    echo -e "${GREEN}All network settings reset to defaults${NC}"
}

# Main menu
main_menu() {
    while true; do
        clear
        echo -e "${YELLOW}=== Manual TCP Optimizer ===${NC}"
        echo "1. Apply Basic TCP Optimizations"
        echo "2. Apply Advanced TCP Optimizations"
        echo "3. Enable BBR"
        echo "4. Enable BBR2 (if available)"
        echo "5. Enable Cubic (default)"
        echo "6. Reset All Settings"
        echo "7. Check Current Settings"
        echo "8. Exit"
        echo -n "Select option [1-8]: "
        
        read choice
        case $choice in
            1) basic_tcp_optimize ;;
            2) advanced_tcp_optimize ;;
            3) enable_bbr ;;
            4) enable_bbr2 ;;
            5) enable_cubic ;;
            6) reset_settings ;;
            7) check_status ;;
            8) exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

main_menu
