#!/bin/bash

set -e

# Configuration Files
CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
DNS_CONFIG="/etc/systemd/resolved.conf"
NETPLAN_DIR="/etc/netplan/"
GRUB_CONFIG="/etc/default/grub"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo bash $0)${NC}"
    exit 1
  fi
}

show_menu() {
  clear
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${GREEN} Ultimate Gaming/Streaming Network Optimizer ${NC}"
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "1) Install ${GREEN}Ultra-Tuned BBRv3${NC} for Gaming"
  echo -e "2) Set Custom DNS (Cloudflare/Google/Custom)"
  echo -e "3) Set ${YELLOW}Precise MTU${NC} (Auto-Detect Optimal)"
  echo -e "4) Apply ${GREEN}All Optimizations${NC}"
  echo -e "5) Reboot System"
  echo -e "6) View Current Settings"
  echo -e "0) Exit"
  echo -e "${YELLOW}==============================================${NC}"
  read -rp "Select option [0-6]: " opt
}

optimize_bbr() {
  echo -e "${GREEN}🚀 Applying Ultra-Tuned BBRv3 for Gaming/Streaming...${NC}"

  # Kernel Parameters
  cat > "$CONFIG_FILE" <<'EOF'
# Ultra-Tuned BBRv3 Parameters for Gaming/Streaming
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# Advanced Buffer Management
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_mem = 4096 87380 33554432

# Latency Reduction
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_workaround_signed_windows = 1

# Gaming/Streaming Optimizations
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_frto = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# Connection Stability
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fin_timeout = 10

# Queue Management
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
EOF

  # Apply settings
  sysctl --system
  
  # Enable BBRv3 module
  echo "tcp_bbr" | tee /etc/modules-load.d/bbr.conf
  modprobe tcp_bbr

  # Update GRUB (for kernel parameters)
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash tcp_congestion_control=bbr ipv4.tcp_wmem=4096 65536 33554432 ipv4.tcp_rmem=4096 87380 33554432"/' "$GRUB_CONFIG"
  update-grub

  echo -e "${GREEN}✅ Ultra-Tuned BBRv3 Successfully Configured!${NC}"
}

set_dns() {
  echo -e "\n${YELLOW}🌐 Select DNS Provider:${NC}"
  echo "1) Cloudflare (1.1.1.1 - Best for Gaming)"
  echo "2) Google (8.8.8.8 - Reliable)"
  echo "3) OpenDNS (208.67.222.222 - Secure)"
  echo "4) Custom (Enter manually)"
  read -rp "Your choice [1-4]: " dns_opt

  case $dns_opt in
    1) DNS_SERVERS="1.1.1.1 1.0.0.1" ;;
    2) DNS_SERVERS="8.8.8.8 8.8.4.4" ;;
    3) DNS_SERVERS="208.67.222.222 208.67.220.220" ;;
    4) read -rp "Enter custom DNS (space separated): " DNS_SERVERS ;;
    *) echo -e "${RED}Invalid option${NC}"; return ;;
  esac

  # Configure systemd-resolved
  mkdir -p /etc/systemd/resolved.conf.d/
  cat > "/etc/systemd/resolved.conf.d/dns.conf" <<EOF
[Resolve]
DNS=$DNS_SERVERS
FallbackDNS=9.9.9.9 149.112.112.112
DNSSEC=allow-downgrade
Cache=yes
DNSStubListener=yes
EOF

  systemctl restart systemd-resolved
  systemctl enable systemd-resolved
  echo -e "${GREEN}✅ DNS Configured: $DNS_SERVERS (Persistent after reboot)${NC}"
}

set_mtu() {
  # Detect active interface
  INTERFACE=$(ip route | grep default | awk '{print $5}')
  CURRENT_MTU=$(cat /sys/class/net/$INTERFACE/mtu)
  
  echo -e "\n${YELLOW}📦 Current MTU: $CURRENT_MTU${NC}"
  echo -e "Recommended values:"
  echo -e "1) Ethernet: 1500 (Default)"
  echo -e "2) PPPoE: 1492"
  echo -e "3) VPN: 1400-1420"
  echo -e "4) Custom value"
  
  read -rp "Select MTU option [1-4]: " mtu_opt
  
  case $mtu_opt in
    1) NEW_MTU=1500 ;;
    2) NEW_MTU=1492 ;;
    3) NEW_MTU=1420 ;;
    4) 
      while true; do
        read -rp "Enter custom MTU (68-9000): " NEW_MTU
        if [[ $NEW_MTU -ge 68 && $NEW_MTU -le 9000 ]]; then
          break
        else
          echo -e "${RED}Invalid MTU! Must be between 68-9000${NC}"
        fi
      done
      ;;
    *) echo -e "${RED}Invalid option${NC}"; return ;;
  esac

  # Apply MTU to all possible config locations
  echo -e "${YELLOW}🔧 Applying MTU $NEW_MTU to $INTERFACE...${NC}"
  
  # Netplan configuration
  if [ -d "$NETPLAN_DIR" ]; then
    NETPLAN_FILE=$(ls $NETPLAN_DIR/*.yaml | head -1)
    if [ -f "$NETPLAN_FILE" ]; then
      if grep -q "mtu" "$NETPLAN_FILE"; then
        sed -i "s/mtu:.*/mtu: $NEW_MTU/" "$NETPLAN_FILE"
      else
        sed -i "/$INTERFACE:/a \      mtu: $NEW_MTU" "$NETPLAN_FILE"
      fi
      netplan apply
    fi
  fi

  # Interface configuration
  ip link set dev "$INTERFACE" mtu "$NEW_MTU"
  
  # Persistent MTU setting
  cat > "/etc/network/if-up.d/mtu" <<EOF
#!/bin/sh
[ "\$IFACE" = "$INTERFACE" ] || exit 0
ip link set dev "$INTERFACE" mtu $NEW_MTU
EOF

  chmod +x /etc/network/if-up.d/mtu
  echo -e "${GREEN}✅ MTU set to $NEW_MTU (Persistent after reboot)${NC}"
}

apply_all() {
  optimize_bbr
  set_dns
  set_mtu
  echo -e "${GREEN}🚀 All optimizations applied successfully!${NC}"
}

reboot_system() {
  read -rp "Are you sure you want to reboot? [y/N]: " choice
  case "$choice" in
    y|Y) 
      echo -e "${YELLOW}🔄 Rebooting system...${NC}"
      reboot
      ;;
    *) 
      echo -e "${YELLOW}Reboot cancelled.${NC}"
      ;;
  esac
}

show_status() {
  echo -e "\n${GREEN}📊 Current Network Settings:${NC}"
  echo -e "${YELLOW}--------------------------------${NC}"
  echo -e "BBR Status: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
  echo -e "Queue Discipline: $(sysctl net.core.default_qdisc | awk '{print $3}')"
  echo -e "DNS Servers: $(systemd-resolve --status | grep 'DNS Servers' | awk '{print $3}')"
  echo -e "MTU Size: $(ip link show | grep mtu | awk '{print $5}')"
  echo -e "IPv4 TCP Memory: $(sysctl net.ipv4.tcp_mem | awk '{print $3 " " $4 " " $5}')"
  echo -e "IPv4 TCP Window Scaling: $(sysctl net.ipv4.tcp_window_scaling | awk '{print $3}')"
  echo -e "${YELLOW}--------------------------------${NC}"
  read -rp "Press Enter to continue..."
}

main() {
  check_root
  while true; do
    show_menu
    case $opt in
      1) optimize_bbr ;;
      2) set_dns ;;
      3) set_mtu ;;
      4) apply_all ;;
      5) reboot_system ;;
      6) show_status ;;
      0) 
        echo -e "${GREEN}Exiting...${NC}"
        exit 0
        ;;
      *) 
        echo -e "${RED}Invalid option${NC}"
        sleep 1
        ;;
    esac
  done
}

main
