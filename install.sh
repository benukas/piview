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

# Download to a persistent location so user can run setup interactively
INSTALL_DIR="$HOME/piview-install"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Downloading Piview..."
# Download the repository files
curl -sSL https://github.com/benukas/piview/archive/refs/heads/main.tar.gz -o piview.tar.gz
tar -xzf piview.tar.gz --strip-components=1
rm -f piview.tar.gz

# Make scripts executable
chmod +x setup.sh

echo ""
echo -e "${GREEN}=========================================="
echo "Download Complete!"
echo "==========================================${NC}"
echo ""
echo "Files downloaded to: $INSTALL_DIR"
echo ""
echo "Now running setup interactively..."
echo ""
echo "You will be prompted to configure:"
echo "  - WiFi (optional)"
echo "  - URL to display"
echo "  - Refresh interval"
echo "  - SSL certificate handling"
echo "  - Read-only mode (optional)"
echo ""
sleep 2

# Run setup.sh in a new shell session to ensure interactivity
bash ./setup.sh

# Cleanup after setup completes
echo ""
echo "Cleaning up temporary files..."
cd "$HOME"
rm -rf "$INSTALL_DIR"

echo ""
echo -e "${GREEN}=========================================="
echo "Installation Complete!"
echo "==========================================${NC}"
echo ""
echo "Piview has been installed and configured."
echo "Reboot your Raspberry Pi to start in kiosk mode."
echo ""
