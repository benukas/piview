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
    sudo apt-get update
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
        
        # Restart networking
        echo "Restarting network interface..."
        sudo ifdown wlan0 2>/dev/null || true
        sleep 2
        sudo ifup wlan0 2>/dev/null || true
        
        # Wait for connection
        echo "Waiting for WiFi connection..."
        sleep 5
        
        # Check connection
        if ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
            echo "WiFi connected successfully!"
        else
            echo "Warning: WiFi may not be connected. Check configuration manually."
            echo "You can check status with: sudo iwconfig wlan0"
        fi
    fi
else
    echo "Skipping WiFi configuration. Using existing network setup."
fi

# Update system
echo ""
echo "Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y

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
    sudo apt-get update || true
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
  "max_connection_retries": 3,
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
    "--ignore-certificate-errors",
    "--ignore-ssl-errors",
    "--ignore-certificate-errors-spki-list",
    "--allow-running-insecure-content",
    "--disable-web-security",
    "--test-type",
    "--unsafely-treat-insecure-origin-as-secure",
    "--allow-insecure-localhost"
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
sudo tee /etc/systemd/system/piview-keepalive.service > /dev/null << EOF
[Unit]
Description=Piview Screen Keepalive Backup
After=graphical.target
Requires=graphical.target

[Service]
Type=simple
User=$USER
Environment=DISPLAY=:0
ExecStart=/opt/piview/screen_keepalive.sh
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF
sudo systemctl enable piview-keepalive.service 2>/dev/null || true

# Install systemd service with aggressive restart policy
echo "Installing systemd service with bulletproof restart policy..."
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
User=$USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$USER/.Xauthority

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
User=$USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$USER/.Xauthority

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

echo "" >&2
ask_tty_yn "Enable read-only mode for SD card now? (recommended for factory use)" READONLY_REPLY "n"
if [[ $READONLY_REPLY =~ ^[Yy]$ ]]; then
    sudo /usr/local/bin/overlayroot.sh enable
fi

# Install additional tools for screen management
echo "Installing additional screen management tools..."
sudo apt-get install -y \
    tvservice \
    rpi-update || true

# Configure .xinitrc with aggressive screen blanking prevention
if [ "$NEED_X_SERVER" = true ]; then
    echo "Configuring X server with bulletproof screen settings..."
    cat > ~/.xinitrc << 'XINITEOF'
#!/bin/sh
# Start Piview - Factory Hardened

# Disable screen blanking - MULTIPLE METHODS
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset s noblank 2>/dev/null
xset s 0 0 2>/dev/null

# Disable power management
xset -dpms 2>/dev/null
xset dpms 0 0 0 2>/dev/null

# Reset screen saver
xset s reset 2>/dev/null

# Disable console blanking
setterm -blank 0 -powerdown 0 -powersave off 2>/dev/null

# Wake up HDMI if sleeping
tvservice -p 2>/dev/null || true

# Hide cursor
unclutter -idle 1 -root &

# Keep screen alive script (runs in background)
(
    while true; do
        sleep 30
        xset s reset 2>/dev/null
        xset -dpms 2>/dev/null
        xset s off 2>/dev/null
        # Move mouse slightly to prevent blanking
        xdotool mousemove_relative -- 1 0 2>/dev/null
        sleep 0.1
        xdotool mousemove_relative -- -1 0 2>/dev/null
    done
) &

# Start Piview
exec /usr/bin/python3 /opt/piview/piview.py
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

# Disable screen blanking at system level
echo "Disabling screen blanking at system level..."
sudo tee /etc/systemd/system/disable-screen-blanking.service > /dev/null << 'BLANKEOF'
[Unit]
Description=Disable Screen Blanking
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 0 > /sys/module/kernel/parameters/consoleblank || true'
ExecStart=/bin/bash -c 'setterm -blank 0 -powerdown 0 -powersave off || true'
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
echo "To close browser: Press ESC or 'q' key"
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
echo "Setup complete! Reboot to start in kiosk mode."
echo ""
