#!/bin/bash

# Ultimate Xray Optimizer with Media Support
# Now with Instagram Music & Spotify on All Ports

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Backup Directory
BACKUP_DIR="/opt/xray_backup_$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# Function 1: Install Dependencies
install_deps() {
    echo -e "${YELLOW}[1] Installing dependencies...${NC}"
    apt-get update > /dev/null
    apt-get install -y \
        jq net-tools dnsutils \
        iptables-persistent fail2ban \
        brotli zlib1g-dev docker.io > /dev/null
    echo -e "${GREEN}Dependencies installed!${NC}"
}

# Function 2: Optimize Network Stack
optimize_network() {
    echo -e "${YELLOW}[2] Optimizing network stack...${NC}"
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"
    
    cat > /etc/sysctl.conf << EOL
# Optimized Network Settings
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1000000
# Traffic Saving
net.ipv4.tcp_sack = 0
net.ipv4.tcp_dsack = 0
net.ipv4.tcp_fack = 0
EOL
    
    sysctl -p > /dev/null
    echo -e "${GREEN}Network optimization complete!${NC}"
}

# Function 3: Enable Traffic Compression
enable_compression() {
    echo -e "${YELLOW}[3] Enabling traffic compression...${NC}"
    
    if [ -f "/usr/local/etc/xray/config.json" ]; then
        cp /usr/local/etc/xray/config.json "$BACKUP_DIR/xray_config.json.bak"
        
        jq '.inbounds[].streamSettings += {"compression": "auto"}' \
            /usr/local/etc/xray/config.json > /tmp/xray_compressed.json
        
        mv /tmp/xray_compressed.json /usr/local/etc/xray/config.json
        systemctl restart xray
        echo -e "${GREEN}Traffic compression enabled!${NC}"
    else
        echo -e "${RED}Xray not found! Skipping...${NC}"
    fi
}

# Function 4: Optimize WebSocket (WS)
optimize_websocket() {
    echo -e "${YELLOW}[4] Optimizing WebSocket connections...${NC}"
    
    if [ -f "/usr/local/etc/xray/config.json" ]; then
        jq '(.inbounds[] | select(.streamSettings.network == "ws")).streamSettings += {
            "wsSettings": {
                "maxEarlyData": 2048,
                "acceptProxyProtocol": false,
                "path": "/graphql",
                "headers": {
                    "Host": "$host"
                }
            },
            "sockopt": {
                "tcpFastOpen": true,
                "tproxy": "off"
            }
        }' /usr/local/etc/xray/config.json > /tmp/xray_ws_optimized.json
        
        mv /tmp/xray_ws_optimized.json /usr/local/etc/xray/config.json
        systemctl restart xray
        echo -e "${GREEN}WebSocket optimized!${NC}"
    else
        echo -e "${RED}Xray not found! Skipping...${NC}"
    fi
}

# Function 5: Optimize VLESS/TCP
optimize_vless_tcp() {
    echo -e "${YELLOW}[5] Optimizing VLESS/TCP protocol...${NC}"
    
    if [ -f "/usr/local/etc/xray/config.json" ]; then
        jq '(.inbounds[] | select(.protocol == "vless" and .streamSettings.network == "tcp")).streamSettings += {
            "xtlsSettings": {
                "minVersion": "1.2",
                "maxVersion": "1.3",
                "cipherSuites": "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
                "alpn": ["h2", "http/1.1"]
            },
            "sockopt": {
                "tcpFastOpen": true,
                "tproxy": "off"
            }
        }' /usr/local/etc/xray/config.json > /tmp/xray_vless_tcp.json
        
        mv /tmp/xray_vless_tcp.json /usr/local/etc/xray/config.json
        systemctl restart xray
        echo -e "${GREEN}VLESS/TCP optimized!${NC}"
    else
        echo -e "${RED}Xray not found! Skipping...${NC}"
    fi
}

# Function 6: Secure DNS Settings
secure_dns() {
    echo -e "${YELLOW}[6] Securing DNS settings...${NC}"
    cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak"
    
    iptables -A OUTPUT -p udp --dport 53 -j DROP
    iptables -A OUTPUT -p tcp --dport 53 -j DROP
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    
    echo -e "${GREEN}DNS secured!${NC}"
}

# Function 7: Setup Instagram Music (All Ports)
setup_instagram_music() {
    echo -e "${YELLOW}[7] Setting up Instagram Music on all ports...${NC}"
    
    # Create Docker network if not exists
    docker network create xray-net 2>/dev/null
    
    # Run Instagram Music proxy
    docker run -d \
        --name insta-music \
        --network xray-net \
        -p 8080-8090:8080-8090 \
        -e ENABLE_ALL_PORTS=true \
        -e MAX_CONNECTIONS=1000 \
        --restart unless-stopped \
        ghcr.io/instagram-music/proxy:latest > /dev/null
    
    # Allow all ports in firewall
    for port in {8080..8090}; do
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    echo -e "${GREEN}Instagram Music ready on ports 8080-8090!${NC}"
}

# Function 8: Setup Spotify (All Ports)
setup_spotify() {
    echo -e "${YELLOW}[8] Setting up Spotify on all ports...${NC}"
    
    # Run Spotify Connect with port range
    docker run -d \
        --name spotify \
        --network xray-net \
        -p 4000-4010:4000-4010 \
        -e SPOTIFY_USER=your_username \
        -e SPOTIFY_PASSWORD=your_password \
        -e EXTRA_PORTS="4001-4010" \
        --restart unless-stopped \
        spotify/spotify-connect > /dev/null
    
    # Allow all ports in firewall
    for port in {4000..4010}; do
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
    done
    
    echo -e "${GREEN}Spotify ready on ports 4000-4010!${NC}"
}

# Function 9: Reboot Server
reboot_server() {
    echo -e "${YELLOW}[9] Rebooting server...${NC}"
    read -p "Are you sure? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Rebooting now...${NC}"
        reboot
    else
        echo -e "${RED}Reboot cancelled.${NC}"
    fi
}

# Function 10: Install Everything
install_all() {
    echo -e "${YELLOW}[10] Installing ALL optimizations...${NC}"
    install_deps
    optimize_network
    enable_compression
    optimize_websocket
    optimize_vless_tcp
    secure_dns
    setup_instagram_music
    setup_spotify
    echo -e "${GREEN}All optimizations completed!${NC}"
}

# Function 11: Rollback All Changes
rollback_changes() {
    echo -e "${RED}[11] Rolling back all changes...${NC}"
    
    # Restore system configs
    [ -f "$BACKUP_DIR/sysctl.conf.bak" ] && \
        cp "$BACKUP_DIR/sysctl.conf.bak" /etc/sysctl.conf && \
        sysctl -p > /dev/null
    
    [ -f "$BACKUP_DIR/xray_config.json.bak" ] && \
        cp "$BACKUP_DIR/xray_config.json.bak" /usr/local/etc/xray/config.json && \
        systemctl restart xray
    
    [ -f "$BACKUP_DIR/resolv.conf.bak" ] && \
        chattr -i /etc/resolv.conf 2>/dev/null && \
        cp "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf && \
        systemctl enable systemd-resolved 2>/dev/null && \
        systemctl start systemd-resolved 2>/dev/null
    
    # Remove media services
    docker rm -f spotify insta-music 2>/dev/null
    docker network rm xray-net 2>/dev/null
    
    # Clean iptables
    iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
    for port in {4000..4010} {8080..8090}; do
        iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
    done
    
    echo -e "${GREEN}Rollback completed!${NC}"
}

# Show Menu
show_menu() {
    clear
    echo -e "${BLUE}"
    cat << "EOF"
  ___ _   _ _____ _____ _____ _____ _____ _____ 
 / _ \ | | |_   _|_   _| ____|_   _| ____|_   _|
| | | | | | | |   | | |  _|   | | |  _|   | |  
| |_| | |_| | |   | | | |___  | | | |___  | |  
 \___/ \___/  |_|  |_| |_____| |_| |_____| |_|  
EOF
    echo -e "${NC}"
    echo "----------------------------------------"
    echo -e "${YELLOW}Select an option:${NC}"
    echo "1) Install dependencies"
    echo "2) Optimize network stack"
    echo "3) Enable traffic compression"
    echo "4) Optimize WebSocket (WS)"
    echo "5) Optimize VLESS/TCP"
    echo "6) Secure DNS settings"
    echo -e "${GREEN}7) Setup Instagram Music (All Ports)"
    echo -e "${GREEN}8) Setup Spotify (All Ports)${NC}"
    echo "9) Reboot server"
    echo "10) Install ALL optimizations"
    echo -e "${RED}11) Rollback all changes${NC}"
    echo -e "${RED}q) Quit${NC}"
    echo "----------------------------------------"
}

# Main Execution
while true; do
    show_menu
    read -p "Enter your choice (1-11/q): " choice
    
    case $choice in
        1) install_deps ;;
        2) optimize_network ;;
        3) enable_compression ;;
        4) optimize_websocket ;;
        5) optimize_vless_tcp ;;
        6) secure_dns ;;
        7) setup_instagram_music ;;
        8) setup_spotify ;;
        9) reboot_server ;;
        10) install_all ;;
        11) rollback_changes ;;
        q|Q) echo -e "${GREEN}Exiting...${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
    
    read -p "Press [Enter] to continue..."
done
