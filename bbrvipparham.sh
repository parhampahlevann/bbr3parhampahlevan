#!/bin/bash

# Ultimate Xray Optimizer - Complete Edition
# Supports Sanaei Panel (Protected Ports: 8880, 443, 23902)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Protected Ports
PROTECTED_PORTS=(8880 443 23902)
BACKUP_DIR="/opt/xray_backup_$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# Detect Xray Installation
detect_xray() {
    local paths=(
        "/usr/local/bin/xray"
        "/usr/sbin/xray" 
        "/usr/bin/xray"
        "$(which xray)"
    )
    
    for path in "${paths[@]}"; do
        if [ -f "$path" ]; then
            XRAY_PATH="$path"
            
            # Try common config locations
            local configs=(
                "/usr/local/etc/xray/config.json"
                "/etc/xray/config.json"
                "$(dirname $XRAY_PATH)/../etc/xray/config.json"
            )
            
            for config in "${configs[@]}"; do
                if [ -f "$config" ]; then
                    CONFIG_PATH="$config"
                    echo -e "${GREEN}Xray found at: $XRAY_PATH${NC}"
                    echo -e "${GREEN}Config found at: $CONFIG_PATH${NC}"
                    return 0
                fi
            done
        fi
    done
    
    echo -e "${RED}Xray installation not detected!${NC}"
    return 1
}

# Backup Config
backup_config() {
    echo -e "${YELLOW}Creating backup...${NC}"
    cp "$CONFIG_PATH" "$BACKUP_DIR/xray_config_$(date +%s).json"
    echo -e "${GREEN}Backup created in $BACKUP_DIR${NC}"
}

# Function 1: Full TCP Optimization (Safe Mode)
optimize_tcp() {
    echo -e "${YELLOW}[1] Optimizing TCP Stack (Safe Mode)...${NC}"
    
    # Backup
    cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"
    
    # Apply optimizations (excluding protected ports)
    cat > /etc/sysctl.conf << EOL
# TCP Optimizations (Protected Ports: ${PROTECTED_PORTS[@]})
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.core.default_qdisc = fq
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1000000
fs.nr_open = 1000000
vm.swappiness = 10
vm.vfs_cache_pressure = 50
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 32768
net.ipv4.tcp_max_tw_buckets = 2000000

# Traffic Saving
net.ipv4.tcp_sack = 0
net.ipv4.tcp_dsack = 0
net.ipv4.tcp_fack = 0
EOL

    sysctl -p > /dev/null
    
    # Protect specific ports
    for port in "${PROTECTED_PORTS[@]}"; do
        echo 0 > /proc/sys/net/ipv4/tcp_slow_start_after_idle_port_$port 2>/dev/null
    done
    
    echo -e "${GREEN}TCP stack optimized (Protected ports excluded)!${NC}"
}

# Function 2: Xray Core Optimization
optimize_xray_core() {
    if ! detect_xray; then
        echo -e "${RED}Skipping Xray optimization...${NC}"
        return 1
    fi
    
    backup_config
    
    echo -e "${YELLOW}[2] Optimizing Xray Core...${NC}"
    
    # Create temp config
    TEMP_CONFIG="/tmp/xray_optimized_$(date +%s).json"
    
    # Process config with jq (protecting specified ports)
    jq --argjson protected "$(printf '%s\n' "${PROTECTED_PORTS[@]}" | jq -R . | jq -s .)" '
    .inbounds |= map(
        if (.port | tonumber) as $port | ($protected | index($port)) == null then
            .streamSettings += {
                "sockopt": {
                    "tcpFastOpen": true,
                    "tproxy": "off"
                },
                "compression": "auto",
                "tcpSettings": {
                    "header": {
                        "type": "none"
                    },
                    "acceptProxyProtocol": false
                }
            }
        else
            .
        end
    )' "$CONFIG_PATH" > "$TEMP_CONFIG"
    
    # Validate config
    if "$XRAY_PATH" -test -c "$TEMP_CONFIG" 2>/dev/null; then
        mv "$TEMP_CONFIG" "$CONFIG_PATH"
        systemctl restart xray
        echo -e "${GREEN}Xray core optimized!${NC}"
    else
        echo -e "${RED}Invalid configuration generated! Keeping original config.${NC}"
        rm -f "$TEMP_CONFIG"
    fi
}

# Function 3: VLESS/TCP Optimization
optimize_vless_tcp() {
    if ! detect_xray; then
        echo -e "${RED}Skipping VLESS optimization...${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}[3] Optimizing VLESS/TCP...${NC}"
    
    TEMP_CONFIG="/tmp/xray_vless_$(date +%s).json"
    
    jq --argjson protected "$(printf '%s\n' "${PROTECTED_PORTS[@]}" | jq -R . | jq -s .)" '
    (.inbounds[] | select(.protocol == "vless" and .streamSettings.network == "tcp")) |= 
    if (.port | tonumber) as $port | ($protected | index($port)) == null then
        .streamSettings += {
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
        }
    else
        .
    end' "$CONFIG_PATH" > "$TEMP_CONFIG"
    
    if "$XRAY_PATH" -test -c "$TEMP_CONFIG" 2>/dev/null; then
        mv "$TEMP_CONFIG" "$CONFIG_PATH"
        systemctl restart xray
        echo -e "${GREEN}VLESS/TCP optimized!${NC}"
    else
        echo -e "${RED}Failed to optimize VLESS!${NC}"
        rm -f "$TEMP_CONFIG"
    fi
}

# Function 4: WebSocket Optimization
optimize_websocket() {
    if ! detect_xray; then
        echo -e "${RED}Skipping WebSocket optimization...${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}[4] Optimizing WebSocket...${NC}"
    
    TEMP_CONFIG="/tmp/xray_ws_$(date +%s).json"
    
    jq --argjson protected "$(printf '%s\n' "${PROTECTED_PORTS[@]}" | jq -R . | jq -s .)" '
    (.inbounds[] | select(.streamSettings.network == "ws")) |= 
    if (.port | tonumber) as $port | ($protected | index($port)) == null then
        .streamSettings += {
            "wsSettings": {
                "maxEarlyData": 2048,
                "acceptProxyProtocol": false,
                "path": "/$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')",
                "headers": {
                    "Host": "$host"
                }
            },
            "sockopt": {
                "tcpFastOpen": true,
                "tproxy": "off"
            }
        }
    else
        .
    end' "$CONFIG_PATH" > "$TEMP_CONFIG"
    
    if "$XRAY_PATH" -test -c "$TEMP_CONFIG" 2>/dev/null; then
        mv "$TEMP_CONFIG" "$CONFIG_PATH"
        systemctl restart xray
        echo -e "${GREEN}WebSocket optimized with random path!${NC}"
    else
        echo -e "${RED}Failed to optimize WebSocket!${NC}"
        rm -f "$TEMP_CONFIG"
    fi
}

# Function 5: Install Media Services
install_media() {
    echo -e "${YELLOW}[5] Installing Media Services...${NC}"
    
    # Find available ports (excluding protected ports)
    find_available_port() {
        while true; do
            local port=$(( (RANDOM % 60000) + 2000 ))
            if [[ ! " ${PROTECTED_PORTS[@]} " =~ " ${port} " ]] && ! ss -tuln | grep -q ":${port} "; then
                echo $port
                return
            fi
        done
    }
    
    # Instagram Music
    INSTA_PORT=$(find_available_port)
    docker run -d \
        --name insta-music \
        -p $INSTA_PORT:$INSTA_PORT \
        -e "PORT=$INSTA_PORT" \
        -e "BLOCKED_PORTS=${PROTECTED_PORTS[@]}" \
        --restart unless-stopped \
        ghcr.io/instagram-music/proxy:latest
    
    # Spotify
    SPOTIFY_PORT=$(find_available_port)
    docker run -d \
        --name spotify \
        -p $SPOTIFY_PORT:$SPOTIFY_PORT \
        -e "SPOTIFY_USER=your_username" \
        -e "SPOTIFY_PASSWORD=your_password" \
        -e "PORT=$SPOTIFY_PORT" \
        -e "BLOCKED_PORTS=${PROTECTED_PORTS[@]}" \
        --restart unless-stopped \
        spotify/spotify-connect
    
    echo -e "${GREEN}Media services installed on random safe ports!${NC}"
    echo -e "Instagram Music: ${BLUE}http://your-server-ip:$INSTA_PORT${NC}"
    echo -e "Spotify: ${BLUE}http://your-server-ip:$SPOTIFY_PORT${NC}"
}

# Function 6: Secure DNS
secure_dns() {
    echo -e "${YELLOW}[6] Securing DNS...${NC}"
    
    # Backup
    cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak"
    
    # Apply settings (protect Sanaei panel ports)
    for port in "${PROTECTED_PORTS[@]}"; do
        iptables -I OUTPUT -p udp --sport $port --dport 53 -j ACCEPT
        iptables -I OUTPUT -p tcp --sport $port --dport 53 -j ACCEPT
    done
    
    iptables -A OUTPUT -p udp --dport 53 -j DROP
    iptables -A OUTPUT -p tcp --dport 53 -j DROP
    
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf
    
    echo -e "${GREEN}DNS secured (Protected ports excluded)!${NC}"
}

# Function 7: Install All
install_all() {
    echo -e "${YELLOW}[7] Installing ALL Optimizations...${NC}"
    optimize_tcp
    optimize_xray_core
    optimize_vless_tcp
    optimize_websocket
    secure_dns
    install_media
    echo -e "${GREEN}All optimizations completed!${NC}"
}

# Function 8: Rollback
rollback() {
    echo -e "${RED}[8] Rolling Back ALL Changes...${NC}"
    
    # Restore sysctl
    [ -f "$BACKUP_DIR/sysctl.conf.bak" ] && \
        cp "$BACKUP_DIR/sysctl.conf.bak" /etc/sysctl.conf && \
        sysctl -p > /dev/null
    
    # Restore Xray config
    if detect_xray; then
        local latest_backup=$(ls -t "$BACKUP_DIR"/xray_config_*.json 2>/dev/null | head -1)
        [ -f "$latest_backup" ] && \
            cp "$latest_backup" "$CONFIG_PATH" && \
            systemctl restart xray
    fi
    
    # Restore DNS
    [ -f "$BACKUP_DIR/resolv.conf.bak" ] && \
        chattr -i /etc/resolv.conf 2>/dev/null && \
        cp "$BACKUP_DIR/resolv.conf.bak" /etc/resolv.conf
    
    # Remove media
    docker rm -f spotify insta-music 2>/dev/null
    
    # Clean iptables
    iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null
    iptables -D OUTPUT -p tcp --dport 53 -j DROP 2>/dev/null
    
    echo -e "${GREEN}Rollback completed!${NC}"
}

# Function 9: Reboot
reboot_server() {
    echo -e "${YELLOW}[9] Rebooting Server...${NC}"
    read -p "Are you sure? (y/n) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && reboot
}

# Menu
show_menu() {
    clear
    echo -e "${BLUE}"
    cat << "EOF"
   ___  _____ _   _ _____ _____ _   _ 
  / _ \|_   _| \ | |  ___|  _  | \ | |
 / /_\ \ | | |  \| | |__ | | | |  \| |
 |  _  | | | | . ` |  __|| | | | . ` |
 | | | |_| |_| |\  | |___\ \_/ / |\  |
 \_| |_/\___/\_| \_\____/ \___/\_| \_/
EOF
    echo -e "${NC}"
    echo "----------------------------------------"
    echo -e "${YELLOW}Protected Ports: 8880, 443, 23902${NC}"
    echo "----------------------------------------"
    echo "1) Optimize TCP Stack"
    echo "2) Optimize Xray Core"
    echo "3) Optimize VLESS/TCP"
    echo "4) Optimize WebSocket"
    echo "5) Install Media Services"
    echo "6) Secure DNS"
    echo "7) Install ALL"
    echo -e "${RED}8) Rollback ALL${NC}"
    echo "9) Reboot Server"
    echo "q) Quit"
    echo "----------------------------------------"
}

# Main
while true; do
    show_menu
    read -p "Select option (1-9/q): " choice
    
    case $choice in
        1) optimize_tcp ;;
        2) optimize_xray_core ;;
        3) optimize_vless_tcp ;;
        4) optimize_websocket ;;
        5) install_media ;;
        6) secure_dns ;;
        7) install_all ;;
        8) rollback ;;
        9) reboot_server ;;
        q|Q) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}"; sleep 1 ;;
    esac
    
    read -p "Press [Enter] to continue..."
done
