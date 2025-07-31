#!/bin/bash

set -e

# Configuration Files
CONFIG_FILE="/etc/sysctl.d/99-bbrvipparham.conf"
DNS_CONFIG="/etc/systemd/resolved.conf.d/dns.conf"
NETPLAN_DIR="/etc/netplan/"
GRUB_CONFIG="/etc/default/grub"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo bash $0)${NC}"
    exit 1
  fi
}

fix_netplan() {
  echo -e "${YELLOW}🔧 Fixing Netplan configuration...${NC}"
  
  # Backup existing netplan files
  mkdir -p /root/netplan_backup
  cp ${NETPLAN_DIR}*.yaml /root/netplan_backup/ 2>/dev/null || true
  
  # Disable cloud-init network config if exists
  if [ -f "/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" ]; then
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  fi

  # Create clean netplan config for Hetzner
  cat > "${NETPLAN_DIR}01-netcfg.yaml" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false
      optional: true
EOF

  # Apply netplan
  if netplan generate && netplan apply; then
    echo -e "${GREEN}✅ Netplan configuration fixed successfully${NC}"
  else
    echo -e "${RED}❌ Failed to fix netplan configuration${NC}"
    return 1
  fi
}

fix_openvswitch() {
  echo -e "${YELLOW}🔧 Checking Open vSwitch...${NC}"
  
  if systemctl is-active --quiet ovsdb-server.service; then
    echo -e "${BLUE}ℹ️ Open vSwitch is running, no changes needed${NC}"
    return
  fi

  # Disable openvswitch if not needed
  if dpkg -l | grep -q openvswitch; then
    echo -e "${YELLOW}⚠️ Open vSwitch is installed but not running${NC}"
    read -p "Disable Open vSwitch? (y/N): " choice
    case "$choice" in
      y|Y)
        systemctl stop ovsdb-server.service
        systemctl disable ovsdb-server.service
        echo -e "${GREEN}✅ Open vSwitch disabled${NC}"
        ;;
      *)
        echo -e "${BLUE}ℹ️ Keeping Open vSwitch configuration${NC}"
        ;;
    esac
  fi
}

optimize_gaming() {
  echo -e "${GREEN}🎮 Applying Gaming/Streaming Optimizations...${NC}"

  cat > "$CONFIG_FILE" <<'EOF'
# Gaming Optimized BBRv3 Configuration
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# Network Buffers
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# Latency Reduction
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# Connection Stability
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_fin_timeout = 10
EOF

  sysctl --system
  echo -e "${GREEN}✅ Gaming Optimizations Applied${NC}"
}

set_mtu() {
  INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
  CURRENT_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null || echo "1500")
  
  echo -e "\n${YELLOW}📦 Current MTU on $INTERFACE: $CURRENT_MTU${NC}"
  echo -e "${BLUE}Recommended values:${NC}"
  echo -e "1) Default (1500)"
  echo -e "2) Cloud (1450)"
  echo -e "3) Gaming (1420)"
  echo -e "4) Custom value"
  
  read -rp "Select MTU option [1-4]: " mtu_opt
  
  case $mtu_opt in
    1) NEW_MTU=1500 ;;
    2) NEW_MTU=1450 ;;
    3) NEW_MTU=1420 ;;
    4) 
      while true; do
        read -rp "Enter MTU (576-1500): " NEW_MTU
        if [[ $NEW_MTU -ge 576 && $NEW_MTU -le 1500 ]]; then
          break
        else
          echo -e "${RED}Invalid MTU! Use 576-1500${NC}"
        fi
      done
      ;;
    *) echo -e "${RED}Invalid option${NC}"; return ;;
  esac

  echo -e "${YELLOW}🔧 Applying MTU $NEW_MTU to $INTERFACE...${NC}"
  
  # Temporary change
  ip link set dev "$INTERFACE" mtu "$NEW_MTU"
  
  # Persistent change in netplan
  if [ -d "$NETPLAN_DIR" ]; then
    NETPLAN_FILE="${NETPLAN_DIR}01-netcfg.yaml"
    if [ -f "$NETPLAN_FILE" ]; then
      if grep -q "mtu" "$NETPLAN_FILE"; then
        sed -i "s/mtu:.*/mtu: $NEW_MTU/" "$NETPLAN_FILE"
      else
        sed -i "/$INTERFACE:/a \      mtu: $NEW_MTU" "$NETPLAN_FILE"
      fi
    else
      cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: true
      mtu: $NEW_MTU
EOF
    fi
    
    # Apply netplan
    if netplan generate && netplan apply; then
      echo -e "${GREEN}✅ MTU set to $NEW_MTU on $INTERFACE${NC}"
    else
      echo -e "${RED}❌ Failed to apply MTU via netplan${NC}"
      return 1
    fi
  fi
}

main_menu() {
  while true; do
    clear
    echo -e "${YELLOW}==============================================${NC}"
    echo -e "${GREEN} Advanced Network Optimizer for Hetzner ${NC}"
    echo -e "${YELLOW}==============================================${NC}"
    echo -e "1) Fix Netplan & Open vSwitch Issues"
    echo -e "2) Apply Gaming Optimizations"
    echo -e "3) Set Gaming MTU"
    echo -e "4) View Current Settings"
    echo -e "0) Exit"
    echo -e "${YELLOW}==============================================${NC}"
    
    read -rp "Select option [0-4]: " opt
    
    case $opt in
      1)
        fix_netplan
        fix_openvswitch
        ;;
      2) optimize_gaming ;;
      3) set_mtu ;;
      4)
        echo -e "\n${GREEN}📊 Current Network Settings:${NC}"
        ip a
        echo -e "\n${BLUE}BBR Status:${NC}"
        sysctl net.ipv4.tcp_congestion_control
        echo -e "\n${BLUE}MTU:${NC}"
        ip link show | grep mtu
        read -rp "Press Enter to continue..."
        ;;
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

# Initial checks
check_root
main_menu
