#!/bin/bash
# Piview - One-line installer
# Usage: curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash

set -e

echo "=========================================="
echo "Piview - One-Line Installer"
echo "=========================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ "$EUID" -eq 0 ]; then 
   echo -e "${RED}Please do not run as root.${NC}"
   exit 1
fi

# Download to home directory
INSTALL_DIR="$HOME/piview-install"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Downloading Piview from GitHub..."
echo "This may take a moment depending on your connection..."
echo ""
echo "Note: If GitHub is blocked, see OFFLINE-INSTALL.md for offline installation options"
echo ""

# Download with progress indicator (remove -s to show progress)
# Try GitHub first, fallback to alternative if needed
if curl -L --progress-bar --connect-timeout 10 https://github.com/benukas/piview/archive/refs/heads/main.tar.gz -o piview.tar.gz 2>/dev/null; then
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
    echo "Running setup now (prompts will work even when piped)..."
    echo ""
    ./setup.sh
else
    echo -e "${RED}Error: Failed to download Piview from GitHub${NC}"
    echo ""
    echo "GitHub may be blocked. Try one of these options:"
    echo ""
    echo "1. Offline Installation:"
    echo "   - Download files manually from GitHub (on another network)"
    echo "   - Transfer to Pi via USB/SCP"
    echo "   - Run: bash install-offline.sh"
    echo ""
    echo "2. See OFFLINE-INSTALL.md for detailed offline installation instructions"
    echo ""
    echo "3. Required files for offline install:"
    echo "   - setup.sh"
    echo "   - piview.py"
    echo "   - install-offline.sh"
    echo ""
    exit 1
fi

# Cleanup
cd "$HOME"
rm -rf "$INSTALL_DIR"
