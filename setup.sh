#!/bin/bash
# Piview - One-shot setup script for Raspberry Pi OS Lite
# Sets up kiosk mode with read-only SD card, NTP sync, and auto-start
# Pipe-safe: Works even when piped via curl | bash

set -e

# Helper function to ask questions that work even when piped
ask_tty() {
    local prompt_text=$1
    local var_name=$2
    local default_val=$3
    
    # Send prompt to stderr (screen) so it shows even when piped
    echo -n "$prompt_text [$default_val]: " >&2
    
    # Read from terminal, not from pipe
    read -r response </dev/tty 2>/dev/null || response="$default_val"
    
    if [ -z "$response" ]; then
        eval "$var_name=\"$default_val\""
    else
        eval "$var_name=\"$response\""
    fi
}

ask_tty_yn() {
    local prompt_text=$1
    local var_name=$2
    local default_val=$3
    
    echo -n "$prompt_text [$default_val]: " >&2
    read -n 1 response </dev/tty 2>/dev/null || response="$default_val"
    echo "" >&2
    
    if [ -z "$response" ]; then
        response="$default_val"
    fi
    
    eval "$var_name=\"$response\""
}

echo "=========================================="
echo "Piview - Pi OS Lite Setup"
echo "=========================================="
echo ""

# Check if read-only mode is enabled - must be disabled for installation
echo "Checking filesystem write protection..."
ROOT=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -o ro || echo "")
BOOT=$(findmnt -n -o OPTIONS /boot 2>/dev/null | grep -o ro || echo "")

if [ -n "$ROOT" ] || [ -n "$BOOT" ]; then
    echo ""
    echo "⚠️  ERROR: Read-only filesystem is ENABLED"
    echo ""
    echo "Installation cannot proceed with read-only mode enabled."
    echo "Please disable it first:"
    echo ""
    echo "  1. Run: sudo overlayroot.sh disable"
    echo "  2. Reboot: sudo reboot"
    echo "  3. Run this installer again after reboot"
    echo ""
    echo "Or if you're uninstalling/reinstalling:"
    echo "  1. Run: ./uninstall.sh"
    echo "  2. It will disable read-only and ask you to reboot"
    echo "  3. After reboot, run this installer again"
    echo ""
    exit 1
fi

# Also check cmdline.txt and fstab for read-only flags
if [ -f /boot/cmdline.txt ] && grep -q "fastboot noswap" /boot/cmdline.txt 2>/dev/null; then
    echo ""
    echo "⚠️  WARNING: Read-only flags found in /boot/cmdline.txt"
    echo "   These will be applied on next reboot."
    echo "   Please disable read-only mode first: sudo overlayroot.sh disable"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

if [ -f /etc/fstab ] && grep -q "defaults,ro" /etc/fstab 2>/dev/null; then
    echo ""
    echo "⚠️  WARNING: Read-only flags found in /etc/fstab"
    echo "   These will be applied on next reboot."
    echo "   Please disable read-only mode first: sudo overlayroot.sh disable"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "✓ Filesystem is writable - installation can proceed"
echo ""

# Check if running on Raspberry Pi or VirtualBox
IS_RASPBERRY_PI=false
IS_VIRTUALBOX=false

if [ -f /proc/device-tree/model ] && grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    IS_RASPBERRY_PI=true
    echo "Detected: Raspberry Pi hardware"
elif [ -f /sys/class/dmi/id/product_name ] && grep -qi "virtualbox" /sys/class/dmi/id/product_name 2>/dev/null; then
    IS_VIRTUALBOX=true
    echo "Detected: VirtualBox virtual machine"
    echo "Note: This setup is designed for Raspberry Pi, but will work in VirtualBox for testing."
elif [ -f /sys/class/dmi/id/sys_vendor ] && grep -qi "virtualbox" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    IS_VIRTUALBOX=true
    echo "Detected: VirtualBox virtual machine"
    echo "Note: This setup is designed for Raspberry Pi, but will work in VirtualBox for testing."
else
    echo "Warning: This doesn't appear to be a Raspberry Pi or VirtualBox"
    echo "Some features may not work correctly on this system."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# WiFi Configuration (skip on VirtualBox)
echo ""
echo "=========================================="
echo "WiFi Configuration"
echo "=========================================="
echo ""
if [ "$IS_VIRTUALBOX" = true ]; then
    echo "Skipping WiFi configuration (VirtualBox uses host network)" >&2
    ask_tty_yn "Configure WiFi anyway?" CONFIGURE_WIFI "n"
else
    ask_tty_yn "Configure WiFi?" CONFIGURE_WIFI "n"
fi

if [[ $CONFIGURE_WIFI =~ ^[Yy]$ ]]; then
    # Install WiFi tools if not already installed
    echo "Installing WiFi configuration tools..."
    sudo apt-get install -y wpasupplicant wireless-tools || true
    
    # Get WiFi SSID
    echo "" >&2
    ask_tty "Enter WiFi SSID (network name)" WIFI_SSID ""
    if [ -z "$WIFI_SSID" ]; then
        echo "No SSID provided, skipping WiFi configuration." >&2
    else
        # Ask if password protected
        echo "" >&2
        ask_tty_yn "Is this network password protected? (WPA2)" WIFI_PASS_REPLY "y"
        
        # Backup existing wpa_supplicant.conf
        if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
            sudo cp /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.backup
        fi
        
        if [[ $WIFI_PASS_REPLY =~ ^[Yy]$ ]]; then
            # WPA2 network - get password (hidden)
            echo -n "Enter WiFi password: " >&2
            stty -echo </dev/tty 2>/dev/null || true
            read -r WIFI_PASSWORD </dev/tty 2>/dev/null || WIFI_PASSWORD=""
            stty echo </dev/tty 2>/dev/null || true
            echo "" >&2
            
            # Generate PSK if wpa_passphrase is available
            if command -v wpa_passphrase &> /dev/null; then
                # wpa_passphrase outputs psk=... on a line, extract it
                WIFI_PSK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD" 2>/dev/null | grep "psk=" | grep -v "#" | cut -d= -f2 | tr -d ' ')
            else
                # Fallback: use password in quotes (wpa_supplicant will hash it)
                WIFI_PSK="\"$WIFI_PASSWORD\""
            fi
            
            # Ask for country code (required for WiFi on Pi)
            ask_tty "Enter country code (e.g., US, GB, DE)" COUNTRY_CODE "US"
            
            # Configure wpa_supplicant.conf
            echo "Configuring WiFi (WPA2)..."
            sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$COUNTRY_CODE

network={
    ssid="$WIFI_SSID"
    psk=$WIFI_PSK
    key_mgmt=WPA-PSK
}
WPAEOF
        else
            # Open network (no password)
            ask_tty "Enter country code (e.g., US, GB, DE)" COUNTRY_CODE "US"
            
            echo "Configuring WiFi (open network)..."
            sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$COUNTRY_CODE

network={
    ssid="$WIFI_SSID"
    key_mgmt=NONE
}
WPAEOF
        fi
        
        # Set proper permissions
        sudo chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
        
        # Enable and start wpa_supplicant
        echo "Enabling WiFi..."
        sudo systemctl enable wpa_supplicant 2>/dev/null || true
        sudo systemctl start wpa_supplicant 2>/dev/null || true
        
        # Find WiFi interface (handle both wlan0 and predictable names)
        WIFI_INTERFACE=""
        if [ -d /sys/class/net ]; then
            # Try wlan0 first (legacy)
            if [ -d /sys/class/net/wlan0 ]; then
                WIFI_INTERFACE="wlan0"
            else
                # Try predictable names (wlan*, wlp*, etc.)
                for iface in /sys/class/net/wlan* /sys/class/net/wlp*; do
                    if [ -d "$iface" ]; then
                        WIFI_INTERFACE=$(basename "$iface")
                        break
                    fi
                done
            fi
        fi
        
        # Restart network interface if found
        if [ -n "$WIFI_INTERFACE" ]; then
            echo "Restarting network interface: $WIFI_INTERFACE"
            sudo ifdown "$WIFI_INTERFACE" 2>/dev/null || true
            sleep 2
            sudo ifup "$WIFI_INTERFACE" 2>/dev/null || true
        else
            echo "Warning: Could not detect WiFi interface. You may need to restart networking manually."
        fi
        
        # Wait for connection
        echo "Waiting for WiFi connection..."
        sleep 5
        
        # Check connection
        if ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
            echo "WiFi connected successfully!"
        else
            echo "Warning: WiFi may not be connected. Check configuration manually."
            if [ -n "$WIFI_INTERFACE" ]; then
                echo "You can check status with: sudo iwconfig $WIFI_INTERFACE"
            else
                echo "You can check WiFi status with: sudo iwconfig"
            fi
        fi
    fi
else
    echo "Skipping WiFi configuration. Using existing network setup."
fi

# Ask about updating package lists (optional - can skip if lists are recent)
echo "" >&2
ask_tty_yn "Update package lists? (recommended, but can skip if recently updated)" UPDATE_REPLY "y"
if [[ $UPDATE_REPLY =~ ^[Yy]$ ]] || [ -z "$UPDATE_REPLY" ]; then
    echo ""
    echo "Updating package lists..."
    echo "This may take a few minutes on first run..."
    sudo apt-get update
else
    echo "Skipping package list update"
fi

# Ask about upgrading packages (optional - some orgs prefer install-only)
echo "" >&2
ask_tty_yn "Upgrade all installed packages? (recommended, but some orgs prefer install-only)" UPGRADE_REPLY "n"
if [[ $UPGRADE_REPLY =~ ^[Yy]$ ]]; then
    echo "Upgrading system packages..."
    sudo apt-get upgrade -y
else
    echo "Skipping package upgrades (install-only mode)"
fi

# Configure network failover (LAN priority with WiFi fallback)
echo "" >&2
ask_tty_yn "Would you like to setup network failover? (if LAN goes down, switch to WiFi)" FAILOVER_REPLY "n"

FAILOVER_WIFI_SSID=""
FAILOVER_WIFI_PASSWORD=""
FAILOVER_WIFI_INTERFACE=""

if [[ $FAILOVER_REPLY =~ ^[Yy]$ ]]; then
    echo "" >&2
    ask_tty "Enter WiFi SSID for failover (network name)" FAILOVER_WIFI_SSID ""
    
    if [ -n "$FAILOVER_WIFI_SSID" ]; then
        # Ask if password protected
        echo "" >&2
        ask_tty_yn "Is this failover network password protected? (WPA2)" FAILOVER_PASS_REPLY "y"
        
        if [[ $FAILOVER_PASS_REPLY =~ ^[Yy]$ ]]; then
            # Get password (hidden)
            echo -n "Enter WiFi password: " >&2
            stty -echo </dev/tty 2>/dev/null || true
            read -r FAILOVER_WIFI_PASSWORD </dev/tty 2>/dev/null || FAILOVER_WIFI_PASSWORD=""
            stty echo </dev/tty 2>/dev/null || true
            echo "" >&2
        fi
        
        # Configure failover WiFi network in wpa_supplicant
        echo "Configuring failover WiFi network..."
        
        # Backup existing wpa_supplicant.conf if not already backed up
        if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf.backup ] && [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
            sudo cp /etc/wpa_supplicant/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf.backup
        fi
        
        # Read existing config or create new
        if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
            # Append failover network to existing config
            if [[ $FAILOVER_PASS_REPLY =~ ^[Yy]$ ]]; then
                # Generate PSK
                if command -v wpa_passphrase &> /dev/null; then
                    FAILOVER_PSK=$(wpa_passphrase "$FAILOVER_WIFI_SSID" "$FAILOVER_WIFI_PASSWORD" 2>/dev/null | grep "psk=" | grep -v "#" | cut -d= -f2 | tr -d ' ')
                else
                    FAILOVER_PSK="\"$FAILOVER_WIFI_PASSWORD\""
                fi
                
                echo "" | sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null
                sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null << WPAFAILOVER
network={
    ssid="$FAILOVER_WIFI_SSID"
    psk=$FAILOVER_PSK
    key_mgmt=WPA-PSK
    priority=5
}
WPAFAILOVER
            else
                echo "" | sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null
                sudo tee -a /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null << WPAFAILOVER
network={
    ssid="$FAILOVER_WIFI_SSID"
    key_mgmt=NONE
    priority=5
}
WPAFAILOVER
            fi
        else
            # Create new config with failover network
            ask_tty "Enter country code (e.g., US, GB, DE)" COUNTRY_CODE "US"
            
            if [[ $FAILOVER_PASS_REPLY =~ ^[Yy]$ ]]; then
                if command -v wpa_passphrase &> /dev/null; then
                    FAILOVER_PSK=$(wpa_passphrase "$FAILOVER_WIFI_SSID" "$FAILOVER_WIFI_PASSWORD" 2>/dev/null | grep "psk=" | grep -v "#" | cut -d= -f2 | tr -d ' ')
                else
                    FAILOVER_PSK="\"$FAILOVER_WIFI_PASSWORD\""
                fi
                
                sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null << WPAFAILOVER
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$COUNTRY_CODE

network={
    ssid="$FAILOVER_WIFI_SSID"
    psk=$FAILOVER_PSK
    key_mgmt=WPA-PSK
    priority=5
}
WPAFAILOVER
            else
                sudo tee /etc/wpa_supplicant/wpa_supplicant.conf > /dev/null << WPAFAILOVER
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=$COUNTRY_CODE

network={
    ssid="$FAILOVER_WIFI_SSID"
    key_mgmt=NONE
    priority=5
}
WPAFAILOVER
            fi
        fi
        
        sudo chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
        
        # Find WiFi interface
        if [ -d /sys/class/net/wlan0 ]; then
            FAILOVER_WIFI_INTERFACE="wlan0"
        else
            for iface in /sys/class/net/wlan* /sys/class/net/wlp*; do
                if [ -d "$iface" ]; then
                    FAILOVER_WIFI_INTERFACE=$(basename "$iface")
                    break
                fi
            done
        fi
        
        # Configure network priorities
        if command -v nmcli &> /dev/null; then
            # NetworkManager is available - set up metrics for failover
            ETH_INTERFACE=""
            
            # Find ethernet interface
            if [ -d /sys/class/net/eth0 ]; then
                ETH_INTERFACE="eth0"
            else
                for iface in /sys/class/net/eth* /sys/class/net/en*; do
                    if [ -d "$iface" ]; then
                        ETH_INTERFACE=$(basename "$iface")
                        break
                    fi
                done
            fi
            
            # Configure metrics if interfaces found
            if [ -n "$ETH_INTERFACE" ]; then
                # Set Ethernet to higher priority (lower metric = higher priority)
                ETH_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep "$ETH_INTERFACE" | cut -d: -f1 | head -1)
                if [ -n "$ETH_CONN" ]; then
                    sudo nmcli connection modify "$ETH_CONN" ipv4.route-metric 100 2>/dev/null || true
                    echo "  ✓ Ethernet ($ETH_INTERFACE) set to priority 1 (metric 100)"
                fi
            fi
            
            if [ -n "$FAILOVER_WIFI_INTERFACE" ]; then
                # Set WiFi to lower priority (higher metric = lower priority)
                WIFI_CONN=$(nmcli -t -f NAME,DEVICE connection show | grep "$FAILOVER_WIFI_INTERFACE" | cut -d: -f1 | head -1)
                if [ -n "$WIFI_CONN" ]; then
                    sudo nmcli connection modify "$WIFI_CONN" ipv4.route-metric 200 2>/dev/null || true
                    echo "  ✓ WiFi ($FAILOVER_WIFI_INTERFACE) set to priority 2 (metric 200)"
                fi
            fi
            
            echo "  ✓ Network failover configured: LAN preferred, WiFi ($FAILOVER_WIFI_SSID) fallback"
        else
            echo "  ✓ Network failover configured: LAN preferred, WiFi ($FAILOVER_WIFI_SSID) fallback"
            echo "  Note: NetworkManager not available, failover handled by Piview's health check"
        fi
        
        # Save failover WiFi info to config for Piview
        FAILOVER_CONFIG="{\"failover_wifi_ssid\": \"$FAILOVER_WIFI_SSID\", \"failover_wifi_interface\": \"$FAILOVER_WIFI_INTERFACE\"}"
    else
        echo "No WiFi SSID provided, skipping network failover configuration." >&2
    fi
else
    echo "Skipping network failover configuration."
fi

# Install dependencies
echo "Installing dependencies..."
# Check if we're on Raspberry Pi Desktop (has GUI) or Lite (needs X server)
if [ -n "$DISPLAY" ] || [ -d /usr/share/X11 ]; then
    echo "Detected: Desktop environment (Raspberry Pi Desktop)"
    NEED_X_SERVER=false
else
    echo "Detected: Lite/headless (needs X server)"
    NEED_X_SERVER=true
fi

# Check if browser is already installed
BROWSER_INSTALLED=false
if command -v chromium-browser >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1; then
    BROWSER_INSTALLED=true
    echo "Chromium browser already installed"
fi

# Determine which browser package to install (if needed)
if [ "$BROWSER_INSTALLED" = false ]; then
    # Check which package is available
    if apt-cache search chromium-browser 2>/dev/null | grep -q "^chromium-browser "; then
        BROWSER_PKG="chromium-browser"
    elif apt-cache search chromium 2>/dev/null | grep -q "^chromium "; then
        BROWSER_PKG="chromium"
    else
        # Try both
        BROWSER_PKG="chromium-browser"
    fi
else
    BROWSER_PKG=""
fi

if [ "$NEED_X_SERVER" = true ]; then
    PACKAGES="xserver-xorg xinit x11-xserver-utils xdotool unclutter python3 python3-pip watchdog"
    if [ -n "$BROWSER_PKG" ]; then
        PACKAGES="$BROWSER_PKG $PACKAGES"
    fi
    sudo apt-get install -y $PACKAGES || true
else
    # Desktop already has X server, just install browser and tools
    PACKAGES="xdotool unclutter python3 python3-pip watchdog"
    if [ -n "$BROWSER_PKG" ]; then
        PACKAGES="$BROWSER_PKG $PACKAGES"
    fi
    sudo apt-get install -y $PACKAGES || true
fi

# Install certificate tools (for SSL certificate installation)
sudo apt-get install -y ca-certificates libnss3-tools || true

# Final verification - browser should be available
if ! command -v chromium-browser >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
    echo "Warning: Chromium browser executable not found in PATH"
    echo "Trying alternative installation methods..."
    sudo apt-get install -y chromium-browser 2>/dev/null || \
    sudo apt-get install -y chromium 2>/dev/null || \
    echo "Note: Please ensure Chromium is installed manually if needed"
fi

# Sync time immediately
echo "Syncing time with NTP..."
# Check which time sync service is available
if systemctl list-unit-files | grep -q "^ntp.service"; then
    # Traditional NTP service
    sudo systemctl stop ntp 2>/dev/null || true
    if command -v ntpdate &> /dev/null; then
        sudo ntpdate -s time.nist.gov || sudo ntpdate -s pool.ntp.org || true
    fi
    sudo systemctl start ntp 2>/dev/null || true
    sudo systemctl enable ntp 2>/dev/null || true
elif systemctl list-unit-files | grep -q "^systemd-timesyncd.service"; then
    # systemd-timesyncd (modern default)
    sudo systemctl stop systemd-timesyncd 2>/dev/null || true
    sudo timedatectl set-ntp true
    sudo systemctl start systemd-timesyncd 2>/dev/null || true
    sudo systemctl enable systemd-timesyncd 2>/dev/null || true
    # Force sync
    sudo timedatectl set-time "$(date -u +%Y-%m-%d\ %H:%M:%S)" 2>/dev/null || true
elif command -v chronyd &> /dev/null; then
    # Chrony
    sudo systemctl stop chronyd 2>/dev/null || true
    sudo chronyd -q 2>/dev/null || true
    sudo systemctl start chronyd 2>/dev/null || true
    sudo systemctl enable chronyd 2>/dev/null || true
else
    # Fallback: try to install and use ntpdate
    echo "No time sync service found, installing NTP..."
    sudo apt-get install -y ntp ntpdate || true
    if command -v ntpdate &> /dev/null; then
        sudo ntpdate -s time.nist.gov || sudo ntpdate -s pool.ntp.org || true
    fi
    if systemctl list-unit-files | grep -q "^ntp.service"; then
        sudo systemctl start ntp 2>/dev/null || true
        sudo systemctl enable ntp 2>/dev/null || true
    fi
fi

# Verify time sync is working
echo "Time sync configured. Current time: $(date)"

# Create application directory
APP_DIR="/opt/piview"
echo "Creating application directory at $APP_DIR..."
sudo mkdir -p $APP_DIR
sudo cp piview.py $APP_DIR/
sudo chmod +x $APP_DIR/piview.py

# Create config directory
CONFIG_DIR="/etc/piview"
sudo mkdir -p $CONFIG_DIR

# Configuration prompts
echo "" >&2
echo "==========================================" >&2
echo "Configuration" >&2
echo "==========================================" >&2
echo "" >&2

# Get URL from user or use default
ask_tty "Enter the URL to display" USER_URL "https://example.com"

# Get refresh interval
ask_tty "Enter refresh interval (seconds)" REFRESH_INTERVAL "60"

# Ask about SSL certificate handling
echo "" >&2
echo "SSL Certificate Options:" >&2
echo "  1) Install certificate file (recommended - most secure)" >&2
echo "  2) Ignore SSL errors (for testing/development)" >&2
echo "  3) Use system defaults (no special handling)" >&2
ask_tty "Choose option (1/2/3)" SSL_OPTION "2"

if [[ $SSL_OPTION == "1" ]]; then
    IGNORE_SSL="false"
    echo "" >&2
    ask_tty "Enter path to certificate file (.crt or .pem)" CERT_PATH ""
    
    if [ -n "$CERT_PATH" ] && [ -f "$CERT_PATH" ]; then
        echo "Installing certificate..." >&2
        # Install certificate to system store
        sudo cp "$CERT_PATH" /usr/local/share/ca-certificates/piview-custom.crt
        sudo update-ca-certificates
        
        # Also install to Chromium's certificate store
        CERT_DIR="$HOME/.pki/nssdb"
        mkdir -p "$CERT_DIR"
        
        # Use certutil if available (part of libnss3-tools)
        if command -v certutil &> /dev/null; then
            certutil -d "sql:$CERT_DIR" -A -t "C,," -n "Piview Custom Cert" -i "$CERT_PATH" 2>/dev/null || true
        else
            echo "Installing certutil for certificate management..." >&2
            sudo apt-get install -y libnss3-tools || true
            if command -v certutil &> /dev/null; then
                certutil -d "sql:$CERT_DIR" -A -t "C,," -n "Piview Custom Cert" -i "$CERT_PATH" 2>/dev/null || true
            fi
        fi
        
        echo "Certificate installed successfully!" >&2
        CERT_INSTALLED="true"
    else
        echo "Certificate file not found, falling back to ignore SSL errors" >&2
        IGNORE_SSL="true"
        CERT_INSTALLED="false"
    fi
elif [[ $SSL_OPTION == "2" ]]; then
    IGNORE_SSL="true"
    CERT_INSTALLED="false"
else
    IGNORE_SSL="false"
    CERT_INSTALLED="false"
fi
echo "" >&2

# Build failover config JSON if configured (must be before config file creation)
if [ -n "$FAILOVER_WIFI_SSID" ]; then
    FAILOVER_JSON=",
  \"network_failover_enabled\": true,
  \"failover_wifi_ssid\": \"$FAILOVER_WIFI_SSID\",
  \"failover_wifi_interface\": \"${FAILOVER_WIFI_INTERFACE:-wlan0}\""
else
    FAILOVER_JSON=",
  \"network_failover_enabled\": false"
fi

# Create config file
echo "Creating configuration..."
sudo tee $CONFIG_DIR/config.json > /dev/null << EOF
{
  "url": "$USER_URL",
  "refresh_interval": $REFRESH_INTERVAL,
  "browser": "chromium-browser",
  "ignore_ssl_errors": $IGNORE_SSL,
  "cert_installed": ${CERT_INSTALLED:-false},
  "connection_retry_delay": 5,
  "max_connection_retries": 3$FAILOVER_JSON,
  "kiosk_flags": [
    "--kiosk",
    "--noerrdialogs",
    "--disable-infobars",
    "--disable-session-crashed-bubble",
    "--disable-restore-session-state",
    "--autoplay-policy=no-user-gesture-required",
    "--disable-features=TranslateUI",
    "--disable-ipc-flooding-protection",
    "--disable-background-networking",
    "--disable-default-apps",
    "--disable-sync",
    "--disable-dev-shm-usage",
    "--no-sandbox",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--user-data-dir=/tmp/chromium-ssl-bypass"
  ]
}
EOF

# Copy utility scripts
echo "Installing utility scripts..."
sudo cp close_browser.sh $APP_DIR/ 2>/dev/null || true
sudo cp screen_keepalive.sh $APP_DIR/ 2>/dev/null || true
sudo cp export_logs.sh $APP_DIR/ 2>/dev/null || true
sudo chmod +x $APP_DIR/*.sh 2>/dev/null || true

# Create symlink for easy access to export logs
sudo ln -sf $APP_DIR/export_logs.sh /usr/local/bin/piview-export-logs 2>/dev/null || true

# Install screen keepalive as backup service
echo "Installing screen keepalive backup service..."
# Detect user for keepalive service too
KEEPALIVE_USER="${ACTUAL_USER:-${USER:-pi}}"
sudo tee /etc/systemd/system/piview-keepalive.service > /dev/null << EOF
[Unit]
Description=Piview Screen Keepalive Backup
After=graphical.target
Requires=graphical.target

[Service]
Type=simple
User=$KEEPALIVE_USER
Group=$KEEPALIVE_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KEEPALIVE_USER/.Xauthority
ExecStart=/opt/piview/screen_keepalive.sh
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF
sudo systemctl enable piview-keepalive.service 2>/dev/null || true

# Install systemd service with aggressive restart policy
echo "Installing systemd service with bulletproof restart policy..."

# Detect the actual user (fallback to 'pi' if not set)
ACTUAL_USER="${USER:-pi}"
if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
    # Try to get the first non-root user
    ACTUAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' || echo "pi")
fi

echo "Using user: $ACTUAL_USER for systemd service" >&2

if [ "$NEED_X_SERVER" = true ]; then
    # Lite version - needs startx
    sudo tee /etc/systemd/system/piview.service > /dev/null << EOF
[Unit]
Description=Piview Kiosk Mode - Factory Hardened
After=network.target graphical.target
Wants=graphical.target network-online.target
Requires=network-online.target

[Service]
Type=simple
User=$ACTUAL_USER
Group=$ACTUAL_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$ACTUAL_USER/.Xauthority

# Pre-start: Wait for network and prepare
ExecStartPre=/bin/sleep 3

# Main start - startx will handle X server startup
ExecStart=/usr/bin/startx

# Aggressive restart policy
Restart=always
RestartSec=5
StartLimitInterval=0
StartLimitBurst=0

# Kill settings
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=piview

[Install]
WantedBy=graphical.target
EOF
else
    # Desktop version - X server already running
    sudo tee /etc/systemd/system/piview.service > /dev/null << EOF
[Unit]
Description=Piview Kiosk Mode - Factory Hardened
After=network.target graphical.target
Wants=graphical.target network-online.target
Requires=network-online.target

[Service]
Type=simple
User=$ACTUAL_USER
Group=$ACTUAL_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$ACTUAL_USER/.Xauthority

# Pre-start: Wait for X server and ensure screen blanking is disabled
ExecStartPre=/bin/bash -c 'for i in {1..30}; do xset q >/dev/null 2>&1 && break || sleep 1; done'
ExecStartPre=/bin/bash -c 'xset s off -dpms s noblank 2>/dev/null || true'
ExecStartPre=/bin/bash -c 'setterm -blank 0 -powerdown 0 2>/dev/null || true'
ExecStartPre=/bin/sleep 2

# Main start - run directly (X server already running)
ExecStart=/usr/bin/python3 /opt/piview/piview.py

# Aggressive restart policy
Restart=always
RestartSec=5
StartLimitInterval=0
StartLimitBurst=0

# Kill settings
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=piview

[Install]
WantedBy=graphical.target
EOF
fi

# Configure read-only mode script
echo "Creating read-only mode toggle script..."
sudo tee /usr/local/bin/overlayroot.sh > /dev/null << 'OVEREOF'
#!/bin/bash
# Toggle read-only mode for SD card

if [ "$1" = "enable" ]; then
    echo "Enabling read-only mode..."
    
    # Make root filesystem read-only
    sudo mount -o remount,ro / 2>/dev/null || true
    sudo mount -o remount,ro /boot 2>/dev/null || true
    
    # Update cmdline.txt for permanent read-only
    if [ -f /boot/cmdline.txt ]; then
        sudo cp /boot/cmdline.txt /boot/cmdline.txt.backup
        if ! grep -q "fastboot noswap" /boot/cmdline.txt; then
            sudo sed -i 's/$/ fastboot noswap/' /boot/cmdline.txt
        fi
    fi
    
    # Update fstab
    sudo cp /etc/fstab /etc/fstab.backup
    sudo sed -i 's/vfat\s*defaults/vfat defaults,ro/' /etc/fstab 2>/dev/null || true
    sudo sed -i 's/ext4\s*defaults/ext4 defaults,ro/' /etc/fstab 2>/dev/null || true
    
    echo "Read-only mode enabled. Reboot to apply fully."
    echo "To make changes later, run: sudo overlayroot.sh disable"
    
elif [ "$1" = "disable" ]; then
    echo "Disabling read-only mode..."
    
    # Make root filesystem read-write
    sudo mount -o remount,rw / 2>/dev/null || true
    sudo mount -o remount,rw /boot 2>/dev/null || true
    
    # Restore cmdline.txt
    if [ -f /boot/cmdline.txt.backup ]; then
        sudo cp /boot/cmdline.txt.backup /boot/cmdline.txt
    else
        sudo sed -i 's/ fastboot noswap//' /boot/cmdline.txt 2>/dev/null || true
    fi
    
    # Restore fstab
    if [ -f /etc/fstab.backup ]; then
        sudo cp /etc/fstab.backup /etc/fstab
    else
        sudo sed -i 's/vfat defaults,ro/vfat defaults/' /etc/fstab 2>/dev/null || true
        sudo sed -i 's/ext4 defaults,ro/ext4 defaults/' /etc/fstab 2>/dev/null || true
    fi
    
    echo "Read-only mode disabled. Filesystem is now writable."
    
elif [ "$1" = "status" ]; then
    ROOT=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -o ro || echo "")
    BOOT=$(findmnt -n -o OPTIONS /boot 2>/dev/null | grep -o ro || echo "")
    if [ -n "$ROOT" ] || [ -n "$BOOT" ]; then
        echo "Read-only mode: ENABLED"
    else
        echo "Read-only mode: DISABLED"
    fi
else
    echo "Usage: overlayroot.sh {enable|disable|status}"
    echo ""
    echo "  enable  - Enable read-only mode (protects SD card)"
    echo "  disable - Disable read-only mode (allows writes)"
    echo "  status  - Check current read-only status"
fi
OVEREOF
sudo chmod +x /usr/local/bin/overlayroot.sh

# Install additional tools for screen management
echo "Installing additional screen management tools..."
# Note: tvservice is deprecated on newer firmware but kept for compatibility
sudo apt-get install -y \
    unclutter \
    xdotool || true
# tvservice may not be available on newer Pi OS - install if available
sudo apt-get install -y tvservice 2>/dev/null || echo "Note: tvservice not available (deprecated on newer firmware)" || true

# Configure .xinitrc with screen blanking prevention (simplified - Python handles keepalive)
if [ "$NEED_X_SERVER" = true ]; then
    echo "Configuring X server with screen blanking prevention..."
    cat > ~/.xinitrc << 'XINITEOF'
#!/bin/sh
# Start Piview - Factory Hardened
# Screen blanking is handled by: kernel (consoleblank=0) + Python keepalive thread

# Disable screen blanking via X server
xset s off -dpms s noblank 2>/dev/null || true

# Hide cursor
unclutter -idle 1 -root &

# Keep X server alive - restart Piview if it exits
# This ensures X server doesn't close when browser closes
while true; do
    # Start Piview (Python handles keepalive and browser restart)
    /usr/bin/python3 /opt/piview/piview.py
    
    # If Piview exits (shouldn't happen), wait a moment and restart
    # This keeps X server alive even if browser closes
    sleep 2
done
XINITEOF
    chmod +x ~/.xinitrc
else
    echo "Desktop environment detected - X server already running"
    echo "Creating autostart entry instead..."
    mkdir -p ~/.config/autostart
    cat > ~/.config/autostart/piview.desktop << 'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Piview
Exec=/usr/bin/python3 /opt/piview/piview.py
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
DESKTOPEOF
fi

# Disable screen blanking at system level (kernel layer)
# Note: Python keepalive thread handles user-space layer
echo "Disabling screen blanking at system level (kernel)..."
sudo tee /etc/systemd/system/disable-screen-blanking.service > /dev/null << 'BLANKEOF'
[Unit]
Description=Disable Screen Blanking (Kernel Layer)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 0 > /sys/module/kernel/parameters/consoleblank || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BLANKEOF

sudo systemctl enable disable-screen-blanking.service

# Disable sleep/suspend/hibernate (skip on VirtualBox)
if [ "$IS_VIRTUALBOX" != true ]; then
    echo "Disabling system sleep/suspend..."
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
else
    echo "Skipping sleep/suspend disable (VirtualBox handles this)"
fi

# Configure kernel parameters to prevent blanking (skip on VirtualBox)
if [ "$IS_VIRTUALBOX" != true ] && [ -f /boot/cmdline.txt ]; then
    echo "Configuring kernel parameters..."
    if ! grep -q "consoleblank=0" /boot/cmdline.txt 2>/dev/null; then
        sudo sed -i 's/$/ consoleblank=0/' /boot/cmdline.txt
    fi
else
    echo "Skipping kernel parameter configuration (VirtualBox or no /boot/cmdline.txt)"
fi

# Create log directory
echo "Creating log directory..."
sudo mkdir -p /var/log
sudo touch /var/log/piview.log
sudo chmod 666 /var/log/piview.log 2>/dev/null || true

# Configure hardware watchdog (The "Nuke" Option - for kernel freezes)
echo "" >&2
ask_tty_yn "Enable hardware watchdog? (reboots Pi if kernel freezes - recommended for factory)" WATCHDOG_REPLY "y"
if [[ $WATCHDOG_REPLY =~ ^[Yy]$ ]] || [ -z "$WATCHDOG_REPLY" ]; then
    echo "Configuring hardware watchdog..."
    
    # Install watchdog package
    sudo apt-get install -y watchdog || true
    
    # Enable watchdog in boot config (Raspberry Pi only)
    if [ "$IS_RASPBERRY_PI" = true ] && [ -f /boot/config.txt ]; then
        if ! grep -q "^dtparam=watchdog=on" /boot/config.txt 2>/dev/null; then
            echo "Enabling watchdog in /boot/config.txt..."
            echo "dtparam=watchdog=on" | sudo tee -a /boot/config.txt > /dev/null
        else
            echo "Watchdog already enabled in /boot/config.txt"
        fi
    fi
    
    # Configure watchdog service
    if [ -f /etc/watchdog.conf ]; then
        # Uncomment watchdog-device line
        sudo sed -i 's/^#watchdog-device/watchdog-device/' /etc/watchdog.conf 2>/dev/null || true
        sudo sed -i 's/^#.*watchdog-device.*=.*\/dev\/watchdog/watchdog-device = \/dev\/watchdog/' /etc/watchdog.conf 2>/dev/null || true
        
        # Ensure the line exists
        if ! grep -q "^watchdog-device" /etc/watchdog.conf 2>/dev/null; then
            echo "watchdog-device = /dev/watchdog" | sudo tee -a /etc/watchdog.conf > /dev/null
        fi
    fi
    
    # Enable and start watchdog service
    sudo systemctl enable watchdog 2>/dev/null || true
    sudo systemctl start watchdog 2>/dev/null || true
    
    echo "✓ Hardware watchdog configured (Pi will auto-reboot on kernel freeze)"
    echo "  Note: Reboot required for /boot/config.txt changes to take effect"
else
    echo "Hardware watchdog skipped"
fi

# Reload systemd
sudo systemctl daemon-reload
sudo systemctl start disable-screen-blanking.service 2>/dev/null || true

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Configuration: $CONFIG_DIR/config.json"
echo "URL: $USER_URL"
echo "Refresh interval: $REFRESH_INTERVAL seconds"
echo ""
echo "To edit URL, edit the config file:"
echo "  sudo nano $CONFIG_DIR/config.json"
echo ""
echo "To start Piview manually:"
echo "  startx"
echo ""
echo "To enable auto-start on boot:"
echo "  sudo systemctl enable piview.service"
echo ""
echo "To start the service now:"
echo "  sudo systemctl start piview.service"
echo ""
echo "To close browser: Press Alt+F4 or use /opt/piview/close_browser.sh"
echo "To stop Piview: Press Ctrl+C or stop service"
echo ""

if [ -f /usr/local/bin/overlayroot.sh ]; then
    echo "Read-only mode commands:"
    echo "  sudo overlayroot.sh enable   - Enable read-only"
    echo "  sudo overlayroot.sh disable  - Disable read-only"
    echo "  sudo overlayroot.sh status   - Check status"
    echo ""
fi

# Always enable and start by default (bulletproof)
echo "Enabling and starting Piview service..."
sudo systemctl enable piview.service
sudo systemctl start piview.service

# Verify it started
sleep 2
if sudo systemctl is-active --quiet piview.service; then
    echo "✓ Piview service is running"
else
    echo "⚠ Service may need a moment to start. Check with: sudo systemctl status piview.service"
fi

echo ""
echo "=========================================="
echo "Final Step: Read-Only Filesystem (Optional)"
echo "=========================================="
echo ""
echo "Read-only mode protects your SD card from wear, but must be enabled LAST"
echo "after all installation steps are complete."
echo "" >&2
ask_tty_yn "Enable read-only mode for SD card now? (recommended for factory use, but enable only after install completes)" READONLY_REPLY "n"
if [[ $READONLY_REPLY =~ ^[Yy]$ ]]; then
    echo "Enabling read-only mode..."
    sudo /usr/local/bin/overlayroot.sh enable
    echo "Read-only mode enabled. Reboot to apply fully."
else
    echo "Read-only mode skipped. You can enable it later with: sudo overlayroot.sh enable"
fi

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Setup complete! Reboot to start in kiosk mode."
echo ""
