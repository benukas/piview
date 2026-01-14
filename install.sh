#!/bin/bash
# Piview - One-line installer
# Usage: curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash
# OR: bash <(curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh)

set -e

echo "=========================================="
echo "Piview - One-Line Installer"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
   echo -e "${RED}Please do not run as root. The script will use sudo when needed.${NC}"
   exit 1
fi

# Create temporary directory in home to persist if needed
TMP_DIR="$HOME/piview-install-$$"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

echo "Downloading Piview..."
# Download the repository files
curl -sSL https://github.com/benukas/piview/archive/refs/heads/main.tar.gz -o piview.tar.gz
tar -xzf piview.tar.gz
cd piview-main

# Make scripts executable
chmod +x setup.sh

# Run setup (this will prompt for URL, refresh interval, WiFi, etc.)
echo ""
echo -e "${GREEN}=========================================="
echo "Starting Piview Setup"
echo "==========================================${NC}"
echo ""
echo "You will be prompted to configure:"
echo "  - WiFi (optional)"
echo "  - URL to display"
echo "  - Refresh interval"
echo "  - SSL certificate handling"
echo "  - Read-only mode (optional)"
echo ""

# Force interactive mode - run setup.sh directly (not piped)
# This ensures prompts work properly
exec bash ./setup.sh

# Cleanup (only reached if setup.sh exits without exec)
cd /
rm -rf "$TMP_DIR"

echo ""
echo -e "${GREEN}=========================================="
echo "Installation Complete!"
echo "==========================================${NC}"
echo ""
echo "Piview has been installed and configured."
echo "Reboot your Raspberry Pi to start in kiosk mode."
echo ""
