#!/bin/bash
# Enhanced BBRv2 Installation Script
# Supports: Ubuntu 20.04+, Debian 11+, CentOS 8+, AlmaLinux 8+

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

err() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Check root
[ "$EUID" -eq 0 ] || err "This script must be run as root"

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    err "Cannot detect operating system"
fi

# Check kernel version
KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
MIN_KERNEL="5.18"

if [ "$(printf '%s\n' "$MIN_KERNEL" "$KERNEL_VERSION" | sort -V | head -n1)" != "$MIN_KERNEL" ]; then
    err "Kernel $KERNEL_VERSION is too old. BBRv2 requires kernel $MIN_KERNEL+"
fi

# Check if BBRv2 is already enabled
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr2"; then
    log "BBRv2 is already enabled"
    exit 0
fi

# Backup sysctl.conf
cp /etc/sysctl.conf "/etc/sysctl.conf.backup-$(date +%F_%H-%M-%S)"
log "Created sysctl.conf backup"

# Install required packages
install_packages() {
    log "Installing required packages..."
    case "$OS" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y --no-install-recommends ca-certificates curl
            ;;
        centos|almalinux|rocky)
            yum update -y
            yum install -y curl ca-certificates
            ;;
        *)
            err "Unsupported OS: $OS"
            ;;
    esac
}

install_packages

# Check and load BBRv2 module
if ! modprobe tcp_bbr2 2>/dev/null; then
    warn "BBRv2 module not found. Checking for kernel headers..."
    
    # Install kernel headers
    case "$OS" in
        ubuntu|debian)
            apt-get install -y linux-headers-$(uname -r)
            ;;
        centos|almalinux|rocky)
            yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)
            ;;
    esac
    
    # Try to compile BBRv2 module (if headers are available)
    if ! modprobe tcp_bbr2 2>/dev/null; then
        warn "BBRv2 module not available. Using standard BBR instead."
        BBR_FALLBACK=true
    fi
fi

# Configure sysctl parameters
cat <<EOF > /etc/sysctl.d/99-bbr.conf
# BBRv2 Configuration
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${BBR_FALLBACK:-bbr2}
net.ipv4.tcp_nodelay = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_min_snd_mss = 1024
net.ipv4.tcp_autocorking = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_pacing_ss_ratio = 200
net.ipv4.tcp_pacing_ca_ratio = 120
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_congestion_control_dctcp = 1
net.ipv4.tcp_allowed_congestion_control = ${BBR_FALLBACK:-bbr2} reno cubic dctcp
EOF

# Apply settings
sysctl --system

# Verify installation
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [[ "$CURRENT_CC" == "${BBR_FALLBACK:-bbr2}" ]]; then
    log "Successfully enabled ${BBR_FALLBACK:-BBRv2}!"
    log "Current congestion control: $CURRENT_CC"
    log "Current QDisc: $(sysctl -n net.core.default_qdisc)"
    
    # Show kernel module status
    if lsmod | grep -q tcp_bbr2; then
        log "BBRv2 kernel module loaded successfully"
    else
        warn "BBRv2 module not loaded (using built-in support)"
    fi
else
    err "Failed to enable ${BBR_FALLBACK:-BBRv2}. Current: $CURRENT_CC"
fi

# Optional: Reboot prompt
warn "A system reboot is recommended to fully apply all changes"
read -p "Reboot now? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
