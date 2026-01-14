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

echo "Downloading Piview..."
curl -sSL https://github.com/benukas/piview/archive/refs/heads/main.tar.gz -o piview.tar.gz
tar -xzf piview.tar.gz --strip-components=1
rm -f piview.tar.gz
chmod +x setup.sh

echo ""
echo -e "${GREEN}Download complete!${NC}"
echo ""
echo "Running setup now (prompts will work even when piped)..."
echo ""
./setup.sh

# Cleanup
cd "$HOME"
rm -rf "$INSTALL_DIR"
