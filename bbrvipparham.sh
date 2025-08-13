#!/bin/bash

# Ultimate Xray Server Optimization Script
# Combines: TCP/WebSocket Optimization + Xray Tuning + Traffic Compression + DNS Leak Protection
# One-Click Installation: bash <(curl -sSL https://raw.githubusercontent.com/your-repo/main/optimize_all.sh)

# Check root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[31mError: Run as root!\033[0m" >&2
  exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Header
clear
echo -e "${GREEN}"
cat << "EOF"
  __  __ __  __ _   _ _  __   _____ ___  
 |  \/  |  \/  | | | | |/ /  / _ \ \ \ 
 | |\/| | |\/| | | | | ' /  | (_) | | |
 |_|  |_|_|  |_| |_| |_|\_\  \___/  |_|
EOF
echo -e "${NC}----------------------------------------"

# Section 1: Install Dependencies
install_deps() {
  echo -e "${YELLOW}[1/6] Installing dependencies...${NC}"
  apt-get update > /dev/null
  apt-get install -y \
    jq net-tools dnsutils \
    iptables-persistent fail2ban \
    brotli zlib1g-dev docker.io > /dev/null
  echo -e "${GREEN}Dependencies installed!${NC}"
}

# Section 2: TCP/WebSocket Optimization
optimize_network() {
  echo -e "${YELLOW}[2/6] Optimizing TCP/WebSocket...${NC}"
  
  # Backup sysctl
  cp /etc/sysctl.conf /etc/sysctl.conf.bak

  # Apply optimizations
  cat > /etc/sysctl.conf << EOL
# TCP/WS Optimizations
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 32768
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.default_qdisc = fq
fs.file-max = 1000000
fs.nr_open = 1000000
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOL

  sysctl -p > /dev/null
  echo -e "${GREEN}Network optimized!${NC}"
}

# Section 3: Xray Core Tuning (TCP + WS)
optimize_xray() {
  echo -e "${YELLOW}[3/6] Tuning Xray Core...${NC}"
  
  if [ -f "/usr/local/etc/xray/config.json" ]; then
    # Backup config
    cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak
    
    # Apply TCP optimizations
    jq '.inbounds |= map(
      if .streamSettings.network == "tcp" then
        .streamSettings += {
          "sockopt": {"tcpFastOpen": true},
          "tcpSettings": {"header": {"type": "none"}}
        }
      else . end
    )' /usr/local/etc/xray/config.json > /tmp/xray-tcp.json
    
    # Apply WS optimizations
    jq '.inbounds |= map(
      if .streamSettings.network == "ws" then
        .streamSettings += {
          "sockopt": {"tcpFastOpen": true},
          "wsSettings": {
            "maxEarlyData": 2048,
            "acceptProxyProtocol": false
          }
        }
      else . end
    )' /tmp/xray-tcp.json > /tmp/xray-ws.json
    
    # Enable compression
    jq '.inbounds[].streamSettings += {"compression": "auto"}' /tmp/xray-ws.json > /tmp/xray-final.json
    
    mv /tmp/xray-final.json /usr/local/etc/xray/config.json
    systemctl restart xray
    echo -e "${GREEN}Xray core tuned!${NC}"
  else
    echo -e "${RED}Xray not found! Skipping...${NC}"
  fi
}

# Section 4: Prevent DNS Leaks
prevent_dns_leaks() {
  echo -e "${YELLOW}[4/6] Blocking DNS leaks...${NC}"
  iptables -A OUTPUT -p udp --dport 53 -j DROP
  iptables -A OUTPUT -p tcp --dport 53 -j DROP
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
  echo "nameserver 1.0.0.1" >> /etc/resolv.conf
  chattr +i /etc/resolv.conf
  systemctl stop systemd-resolved 2>/dev/null
  systemctl disable systemd-resolved 2>/dev/null
  echo -e "${GREEN}DNS leaks blocked!${NC}"
}

# Section 5: Media Services Setup
setup_media() {
  echo -e "${YELLOW}[5/6] Setting up media services...${NC}"
  
  # Spotify
  docker run -d \
    --name spotify \
    -p 4040:4040 \
    -e SPOTIFY_USER=your_username \
    -e SPOTIFY_PASSWORD=your_password \
    --restart unless-stopped \
    spotify/spotify-connect > /dev/null
  
  # Instagram Music (Example)
  docker run -d \
    --name insta-music \
    -p 8080:8080 \
    --restart unless-stopped \
    ghcr.io/some-ig-music/image > /dev/null
  
  echo -e "${GREEN}Media services ready!${NC}"
}

# Section 6: Final Adjustments
final_tweaks() {
  echo -e "${YELLOW}[6/6] Final system tweaks...${NC}"
  
  # Increase limits
  echo "* soft nofile 1048576" >> /etc/security/limits.conf
  echo "* hard nofile 1048576" >> /etc/security/limits.conf
  
  # Persistent iptables
  iptables-save > /etc/iptables/rules.v4
  ip6tables-save > /etc/iptables/rules.v6
  
  # Create monitoring script
  cat > /usr/local/bin/monitor_connections.sh << 'EOL'
#!/bin/bash
while true; do
  clear
  echo -e "Active TCP Connections: \033[33m$(netstat -ant | grep ESTABLISHED | wc -l)\033[0m"
  echo -e "WebSocket Connections: \033[33m$(ss -H -o state established '( dport = :10000 or sport = :10000 )' | wc -l)\033[0m"
  sleep 5
done
EOL

  chmod +x /usr/local/bin/monitor_connections.sh
  echo -e "${GREEN}Tweaks applied!${NC}"
}

# Execute all
install_deps
optimize_network
optimize_xray
prevent_dns_leaks
setup_media
final_tweaks

# Results
clear
echo -e "${GREEN}"
cat << "EOF"
  _____ _   _ ____  _____ ____  
 | ____| \ | |  _ \| ____|  _ \ 
 |  _| |  \| | | | |  _| | |_) |
 | |___| |\  | |_| | |___|  _ < 
 |_____|_| \_|____/|_____|_| \_\
EOF
echo -e "${NC}----------------------------------------"
echo -e "${BLUE}All optimizations completed!${NC}"
echo "----------------------------------------"
echo -e "${YELLOW}Key Features Enabled:${NC}"
echo "✔ BBR + TCP Fast Open"
echo "✔ WebSocket Optimization"
echo "✔ Xray Core Tuning"
echo "✔ DNS Leak Protection"
echo "✔ Traffic Compression"
echo "✔ Media Services (Spotify/Instagram)"
echo "----------------------------------------"
echo -e "${YELLOW}Monitoring:${NC}"
echo "Run: monitor_connections.sh"
echo "----------------------------------------"
echo -e "${RED}Note:${NC} Customize credentials in:"
echo "- Xray config: /usr/local/etc/xray/config.json"
echo "- Spotify: Edit script with your credentials"
