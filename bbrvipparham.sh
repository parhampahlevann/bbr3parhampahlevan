#!/usr/bin/env bash
# script.sh - launcher for Warp-Multi-IP (fixed for Ubuntu 22/24/25)
# Usage:
#   bash <(curl -Ls https://raw.githubusercontent.com/ParsaKSH/Warp-Multi-IP/main/script.sh)

set -euo pipefail

# ---------- colors ----------
red()   { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow(){ echo -e "\033[33m\033[01m$1\033[0m"; }
blue()  { echo -e "\033[36m\033[01m$1\033[0m"; }

clear || true
echo "=========================================="
echo " Warp-Multi-IP launcher (fixed version)   "
echo "  Repo: github.com/ParsaKSH/Warp-Multi-IP "
echo "=========================================="

# ---------- sudo helper ----------
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

# ---------- basic deps ----------
blue "Checking and installing required packages (python3, curl, wget)..."

if command -v apt-get >/dev/null 2>&1; then
  $SUDO apt-get update -y >/dev/null 2>&1 || true
  $SUDO apt-get install -y python3 python3-venv python3-pip curl wget >/dev/null 2>&1 || {
    red "Failed to install required packages via apt-get."
    exit 1
  }
else
  yellow "apt-get not found. Please install python3, curl and wget manually."
fi

# ---------- prepare working directory ----------
WORKDIR="/root/Warp-Multi-IP"

blue "Preparing working directory at ${WORKDIR} ..."
$SUDO mkdir -p "$WORKDIR"
$SUDO chown "$(id -u):$(id -g)" "$WORKDIR" 2>/dev/null || true

cd "$WORKDIR"

# ---------- download latest warp.py ----------
WARP_URL="https://raw.githubusercontent.com/ParsaKSH/Warp-Multi-IP/main/warp.py"

blue "Downloading latest warp.py from GitHub..."
$SUDO rm -f warp.py

if command -v wget >/dev/null 2>&1; then
  $SUDO wget -q -O warp.py "$WARP_URL"
elif command -v curl >/dev/null 2>&1; then
  $SUDO curl -fsSL -o warp.py "$WARP_URL"
else
  red "Neither wget nor curl is available. Please install one of them."
  exit 1
fi

if [[ ! -s warp.py ]]; then
  red "Failed to download warp.py (file is missing or empty)."
  exit 1
fi

$SUDO chmod +x warp.py

green "warp.py downloaded successfully."

# ---------- run warp.py ----------
blue "Running warp.py (this may take a while)..."

if [[ $EUID -ne 0 ]]; then
  $SUDO python3 warp.py
else
  python3 warp.py
fi

EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
  green "Warp-Multi-IP finished successfully."
else
  red "warp.py exited with code ${EXIT_CODE}."
fi
