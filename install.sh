#!/bin/bash
# Piview Factory-Hardened - One-line installer
# Usage: curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash

set -e

echo "=========================================================="
echo "Piview FACTORY-HARDENED Edition - Installer"
echo "=========================================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Exit if running as root
if [ "$EUID" -eq 0 ]; then 
   echo -e "${RED}ERROR: Do not run as root. Run as your normal user.${NC}"
   echo "The script will ask for sudo when needed."
   exit 1
fi

# Check if Pi OS
if ! grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null && ! grep -q "BCM" /proc/cpuinfo 2>/dev/null; then
    echo -e "${YELLOW}Warning: This doesn't appear to be a Raspberry Pi${NC}"
    exec < /dev/tty
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

INSTALL_DIR="$HOME/piview-install"
PIVIEW_DIR="/opt/piview"

echo ""
echo -e "${BLUE}[1/8]${NC} Downloading Piview from GitHub..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Note: If GitHub is blocked, see OFFLINE-INSTALL.md for alternatives"
echo ""

if curl -L --progress-bar --connect-timeout 10 \
   https://github.com/benukas/piview/archive/refs/heads/main.tar.gz \
   -o piview.tar.gz 2>/dev/null; then
    
    echo ""
    echo "Extracting files..."
    tar -xzf piview.tar.gz --strip-components=1
    rm -f piview.tar.gz
    
    if [ ! -f setup.sh ]; then
        echo -e "${RED}Error: setup.sh not found after download${NC}"
        exit 1
    fi
    
    chmod +x setup.sh
    
    echo ""
    echo -e "${GREEN}Download complete!${NC}"
    echo ""
    echo "Running setup (prompts will work even when piped)..."
    echo ""
    
    # Run setup with proper tty handling
    ./setup.sh
    
    # Cleanup
    cd "$HOME"
    rm -rf "$INSTALL_DIR"
    
    echo ""
    echo -e "${GREEN}Installation complete!${NC}"
    
else
    echo -e "${RED}ERROR: Failed to download from GitHub${NC}"
    echo ""
    echo "Options:"
    echo "1. Check your internet connection"
    echo "2. GitHub may be blocked - use offline install"
    echo "3. See OFFLINE-INSTALL.md in the repo"
    exit 1
fi

echo ""
echo "=========================================================="
echo -e "${GREEN}Installation Complete!${NC}"
echo "=========================================================="
echo ""
echo "For support, issues, or updates:"
echo "https://github.com/benukas/piview"
echo "=========================================================="
