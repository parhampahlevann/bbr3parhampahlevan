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

safe_reboot() {
  echo -e "${YELLOW}⚠️ Creating safe restore point...${NC}"
  mkdir -p /root/network_backup
  cp "$CONFIG_FILE" /root/network_backup/ 2>/dev/null || true
  cp "$DNS_CONFIG" /root/network_backup/ 2>/dev/null || true
  cp -r "$NETPLAN_DIR" /root/network_backup/netplan/ 2>/dev/null || true
  cp "$GRUB_CONFIG" /root/network_backup/ 2>/dev/null || true
  
  cat > /root/network_backup/restore_network.sh <<'EOF'
#!/bin/bash
set -e
echo "Restoring network settings..."
cp -f /root/network_backup/*.conf /etc/sysctl.d/ || true
cp -f /root/network_backup/dns.conf /etc/systemd/resolved.conf.d/ || true
cp -f /root/network_backup/grub /etc/default/ || true
rm -rf /etc/netplan/*
cp -f /root/network_backup/netplan/* /etc/netplan/ || true
sysctl --system
update-grub
netplan apply
systemctl restart systemd-resolved
echo "✅ Network restored!"
EOF
  chmod +x /root/network_backup/restore_network.sh
  echo -e "${GREEN}✅ Restore point created at /root/network_backup${NC}"
}

detect_interface() {
  local iface
  for iface in eth0 enp ens; do
    if ip link show | grep -q "$iface"; then
      INTERFACE=$(ip link show | grep "$iface" | head -1 | awk -F': ' '{print $2}')
      break
    fi
  done

  if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
  fi

  if [ -z "$INTERFACE" ] || ! ip link show "$INTERFACE" &>/dev/null; then
    echo -e "${RED}❌ Interface detection failed!${NC}"
    echo -e "${BLUE}Available interfaces:${NC}"
    ip -o link show | awk -F': ' '{print $2}'
    exit 1
  fi
  echo "$INTERFACE"
}

optimize_gaming() {
  echo -e "${GREEN}🎮 Applying Gaming/Streaming Optimizations...${NC}"

  cat > "$CONFIG_FILE" <<'EOF'
# Ultimate Gaming/Streaming BBRv3 Configuration
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbr

# Gaming-Optimized Buffers
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Low-Latency Tweaks
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_workaround_signed_windows = 1

# Gaming/Streaming Specific
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
net.ipv4.tcp_max_tw_buckets = 2000000

# IPv6 Optimizations
net.ipv6.conf.all.optimize_dst_addr = 1
EOF

  # Apply settings
  sysctl --system
  
  # Enable BBRv3 module
  echo "tcp_bbr" | tee /etc/modules-load.d/bbr.conf
  modprobe tcp_bbr

  # Update GRUB for kernel parameters
  if ! grep -q "tcp_congestion_control=bbr" "$GRUB_CONFIG"; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash tcp_congestion_control=bbr"/' "$GRUB_CONFIG"
    update-grub
  fi

  echo -e "${GREEN}✅ Gaming/Streaming Optimizations Applied!${NC}"
}

set_mtu_gaming() {
  INTERFACE=$(detect_interface)
  CURRENT_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null || echo "1500")
  
  echo -e "\n${YELLOW}📦 Current MTU on $INTERFACE: $CURRENT_MTU${NC}"
  echo -e "${BLUE}Recommended for Gaming:${NC}"
  echo -e "1) Ethernet (1500) - Default"
  echo -e "2) Cloud Gaming (1420)"
  echo -e "3) Low-Latency (1450)"
  echo -e "4) Custom value"
  
  read -rp "Select MTU option [1-4]: " mtu_opt
  
  case $mtu_opt in
    1) NEW_MTU=1500 ;;
    2) NEW_MTU=1420 ;;
    3) NEW_MTU=1450 ;;
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
  
  # Persistent change (Hetzner compatible)
  if [ -d "$NETPLAN_DIR" ]; then
    NETPLAN_FILE=$(ls $NETPLAN_DIR/*.yaml 2>/dev/null | head -1)
    if [ -z "$NETPLAN_FILE" ]; then
      NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"
      cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: true
      mtu: $NEW_MTU
EOF
    else
      if grep -q "$INTERFACE" "$NETPLAN_FILE"; then
        if grep -q "mtu" "$NETPLAN_FILE"; then
          sed -i "/$INTERFACE:/,/mtu:/ s/mtu:.*/mtu: $NEW_MTU/" "$NETPLAN_FILE"
        else
          sed -i "/$INTERFACE:/a \      mtu: $NEW_MTU" "$NETPLAN_FILE"
        fi
      else
        sed -i "/version:/a \  ethernets:\n    $INTERFACE:\n      dhcp4: true\n      mtu: $NEW_MTU" "$NETPLAN_FILE"
      fi
    fi
    
    # Validate Netplan config
    if netplan generate; then
      netplan apply
    else
      echo -e "${RED}❌ Invalid Netplan config! Reverting...${NC}"
      rm -f "$NETPLAN_FILE"
      netplan apply
      return 1
    fi
  fi

  # Verify MTU
  ACTUAL_MTU=$(cat /sys/class/net/$INTERFACE/mtu 2>/dev/null || echo "0")
  if [ "$ACTUAL_MTU" -eq "$NEW_MTU" ]; then
    echo -e "${GREEN}✅ MTU set to $NEW_MTU on $INTERFACE${NC}"
  else
    echo -e "${RED}❌ MTU setting failed! Current: $ACTUAL_MTU${NC}"
  fi
}

show_status() {
  echo -e "\n${GREEN}📊 Current Network Status:${NC}"
  echo -e "${BLUE}--------------------------------${NC}"
  echo -e "Interface: $(detect_interface)"
  echo -e "IPv4 Address: $(ip -4 addr show $(detect_interface) | grep -oP '(?<=inet\s)\d+(\.\d+){3}')"
  echo -e "MTU: $(cat /sys/class/net/$(detect_interface)/mtu 2>/dev/null || echo "Unknown")"
  echo -e "BBR Status: $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')"
  echo -e "Queue Discipline: $(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')"
  echo -e "TCP Rmem: $(sysctl net.ipv4.tcp_rmem | awk '{print $3" "$4" "$5}')"
  echo -e "TCP Wmem: $(sysctl net.ipv4.tcp_wmem | awk '{print $3" "$4" "$5}')"
  echo -e "${BLUE}--------------------------------${NC}"
  echo -e "${YELLOW}Run 'ping -c 5 google.com' to test latency${NC}"
  read -rp "Press Enter to continue..."
}

main_menu() {
  while true; do
    clear
    echo -e "${YELLOW}==============================================${NC}"
    echo -e "${GREEN} Ultimate Gaming/Streaming Network Optimizer ${NC}"
    echo -e "${YELLOW}==============================================${NC}"
    echo -e "1) Apply ${GREEN}Gaming Optimizations${NC} (BBRv3+Tweaks)"
    echo -e "2) Set ${BLUE}Gaming MTU${NC} (Low-Latency)"
    echo -e "3) Create ${YELLOW}Restore Point${NC}"
    echo -e "4) View ${GREEN}Current Settings${NC}"
    echo -e "5) ${RED}Restore Network${NC} (From Backup)"
    echo -e "0) Exit"
    echo -e "${YELLOW}==============================================${NC}"
    
    read -rp "Select option [0-5]: " opt
    
    case $opt in
      1) optimize_gaming ;;
      2) set_mtu_gaming ;;
      3) safe_reboot ;;
      4) show_status ;;
      5)
        if [ -f "/root/network_backup/restore_network.sh" ]; then
          /root/network_backup/restore_network.sh
        else
          echo -e "${RED}❌ No backup found!${NC}"
        fi
        sleep 3
        ;;
      0) 
        echo -e "${GREEN}Exiting...${NC}"
        exit 0
        ;;
      *)
        echo -e "${RED}Invalid option!${NC}"
        sleep 1
        ;;
    esac
  done
}

# Initial checks
check_root
safe_reboot
main_menu
