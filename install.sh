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
GITHUB_URL="https://github.com/benukas/piview/archive/refs/heads/main.tar.gz"

echo ""
echo -e "${BLUE}[1/8]${NC} Downloading Piview from GitHub..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Note: If GitHub is blocked, see OFFLINE-INSTALL.md for alternatives"
echo ""

# Function to download with curl
download_with_curl() {
    local url=$1
    local output=$2
    local exit_code
    echo "Attempting download with curl..."
    curl -L --progress-bar --connect-timeout 30 --max-time 300 \
       --retry 3 --retry-delay 5 \
       --fail --show-error \
       "$url" -o "$output" 2>&1
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        return 0
    else
        echo -e "${YELLOW}Curl download failed, error code: $exit_code${NC}"
        return 1
    fi
}

# Function to download with wget
download_with_wget() {
    local url=$1
    local output=$2
    local exit_code
    echo "Attempting download with wget..."
    wget --progress=bar:force --timeout=30 --tries=3 \
       --retry-connrefused --waitretry=5 \
       "$url" -O "$output" 2>&1
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        return 0
    else
        echo -e "${YELLOW}Wget download failed, error code: $exit_code${NC}"
        return 1
    fi
}

# Check for download tools
HAS_CURL=false
HAS_WGET=false

if command -v curl &> /dev/null; then
    HAS_CURL=true
    echo "Found curl: $(curl --version | head -n1)"
fi

if command -v wget &> /dev/null; then
    HAS_WGET=true
    echo "Found wget: $(wget --version | head -n1)"
fi

if [ "$HAS_CURL" = false ] && [ "$HAS_WGET" = false ]; then
    echo -e "${RED}ERROR: Neither curl nor wget is available${NC}"
    echo "Please install one of them:"
    echo "  sudo apt-get install curl"
    echo "  sudo apt-get install wget"
    exit 1
fi

# Test connectivity first
echo "Testing GitHub connectivity..."
if [ "$HAS_CURL" = true ]; then
    if curl -s --connect-timeout 5 --max-time 10 https://github.com > /dev/null 2>&1; then
        echo -e "${GREEN}GitHub is reachable${NC}"
    else
        echo -e "${YELLOW}Warning: Cannot reach GitHub directly${NC}"
    fi
elif [ "$HAS_WGET" = true ]; then
    if wget -q --spider --timeout=5 https://github.com 2>&1; then
        echo -e "${GREEN}GitHub is reachable${NC}"
    else
        echo -e "${YELLOW}Warning: Cannot reach GitHub directly${NC}"
    fi
fi

# Try downloading
DOWNLOAD_SUCCESS=false

if [ "$HAS_CURL" = true ]; then
    if download_with_curl "$GITHUB_URL" "piview.tar.gz"; then
        DOWNLOAD_SUCCESS=true
    fi
fi

if [ "$DOWNLOAD_SUCCESS" = false ] && [ "$HAS_WGET" = true ]; then
    rm -f piview.tar.gz
    if download_with_wget "$GITHUB_URL" "piview.tar.gz"; then
        DOWNLOAD_SUCCESS=true
    fi
fi

if [ "$DOWNLOAD_SUCCESS" = true ]; then
    # Verify file was downloaded and has content
    if [ ! -f "piview.tar.gz" ] || [ ! -s "piview.tar.gz" ]; then
        echo -e "${RED}Error: Downloaded file is empty or missing${NC}"
        DOWNLOAD_SUCCESS=false
    else
        FILE_SIZE=$(stat -f%z piview.tar.gz 2>/dev/null || stat -c%s piview.tar.gz 2>/dev/null || echo "0")
        if [ "$FILE_SIZE" -lt 1000 ]; then
            echo -e "${RED}Error: Downloaded file is too small (${FILE_SIZE} bytes)${NC}"
            echo "This might be an error page. Showing first 500 characters:"
            head -c 500 piview.tar.gz
            echo ""
            DOWNLOAD_SUCCESS=false
        fi
    fi
fi

if [ "$DOWNLOAD_SUCCESS" = true ]; then
    echo ""
    echo "Extracting files..."
    if tar -xzf piview.tar.gz --strip-components=1 2>&1; then
        rm -f piview.tar.gz
        
        if [ ! -f setup.sh ]; then
            echo -e "${RED}Error: setup.sh not found after extraction${NC}"
            echo "Contents of directory:"
            ls -la
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
        echo -e "${RED}Error: Failed to extract archive${NC}"
        echo "The downloaded file might be corrupted."
        exit 1
    fi
else
    echo ""
    echo -e "${RED}ERROR: Failed to download from GitHub${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check your internet connection: ping -c 3 8.8.8.8"
    echo "2. Test GitHub access: curl -I https://github.com"
    echo "3. Check if behind a proxy (configure in /etc/environment)"
    echo "4. GitHub may be blocked - use offline install method"
    echo ""
    echo "Offline installation options:"
    echo "  - Download files manually and use install-offline.sh"
    echo "  - See OFFLINE-INSTALL.md for detailed instructions"
    echo ""
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
