#!/bin/bash
# Piview - Offline Installer
# This script can be run without GitHub access
# Usage: 
#   1. Download this file and setup.sh, piview.py to your Pi
#   2. Run: bash install-offline.sh

set -e

echo "=========================================="
echo "Piview - Offline Installer"
echo "=========================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -eq 0 ]; then 
   echo -e "${RED}Please do not run as root.${NC}"
   exit 1
fi

# Check if we're in a directory with the required files
if [ ! -f "setup.sh" ]; then
    echo -e "${RED}Error: setup.sh not found in current directory${NC}"
    echo ""
    echo "Please ensure you have the following files in the current directory:"
    echo "  - setup.sh"
    echo "  - piview.py"
    echo "  - install-offline.sh (this file)"
    echo ""
    echo "You can get these files by:"
    echo "  1. Downloading from GitHub on a different network"
    echo "  2. Using a USB drive to transfer files"
    echo "  3. Using scp/sftp to transfer files"
    echo ""
    exit 1
fi

if [ ! -f "piview.py" ]; then
    echo -e "${RED}Error: piview.py not found in current directory${NC}"
    echo ""
    echo "Please ensure you have the following files in the current directory:"
    echo "  - setup.sh"
    echo "  - piview.py"
    echo "  - install-offline.sh (this file)"
    echo ""
    exit 1
fi

echo -e "${GREEN}Required files found!${NC}"
echo ""
echo "Files detected:"
echo "  ✓ setup.sh"
echo "  ✓ piview.py"
echo ""

# Make setup.sh executable
chmod +x setup.sh

echo "Running setup..."
echo ""
./setup.sh

echo ""
echo -e "${GREEN}Installation complete!${NC}"
