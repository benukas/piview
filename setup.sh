#!/bin/bash
# Piview Factory-Hardened Setup Script
# Bulletproof installation for 24/7 industrial deployment

set -e

# Helper functions for piped input
ask_tty() {
    local prompt_text=$1
    local var_name=$2
    local default_val=$3
    
    echo -n "$prompt_text [$default_val]: " >&2
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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -eq 0 ]; then 
   echo -e "${RED}ERROR: Do not run as root${NC}"
   exit 1
fi

echo ""
echo "=========================================================="
echo "Piview Factory-Hardened Setup"
echo "=========================================================="
echo ""

# Check filesystem is writable
ROOT_RO=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -o ro || echo "")
if [ -n "$ROOT_RO" ]; then
    echo -e "${RED}ERROR: Filesystem is read-only${NC}"
    echo "Disable with: sudo overlayroot.sh disable"
    exit 1
fi

echo -e "${GREEN}✓ Filesystem is writable${NC}"

# Check required files
if [ ! -f piview.py ]; then
    echo -e "${RED}ERROR: piview.py not found${NC}"
    exit 1
fi

# Detect platform
IS_PI=false
IS_VBOX=false

if [ -f /proc/device-tree/model ] && grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
    IS_PI=true
    echo "Platform: Raspberry Pi"
elif grep -qi "virtualbox" /sys/class/dmi/id/* 2>/dev/null; then
    IS_VBOX=true
    echo "Platform: VirtualBox (testing)"
else
    echo -e "${YELLOW}Warning: Not a Raspberry Pi${NC}"
    exec < /dev/tty
    read -p "Continue? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Detect user
ACTUAL_USER="${USER:-pi}"
if [ -z "$ACTUAL_USER" ] || [ "$ACTUAL_USER" = "root" ]; then
    ACTUAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' || echo "pi")
fi
echo "Installing for user: $ACTUAL_USER"

# Update packages
echo ""
exec < /dev/tty
ask_tty_yn "Update package lists?" UPDATE_REPLY "y"
if [[ $UPDATE_REPLY =~ ^[Yy]$ ]]; then
    echo "Updating package lists..."
    sudo apt-get update -qq
fi

# Install dependencies
echo ""
echo "Installing dependencies..."

PACKAGES=(
    "chromium-browser"
    "python3"
    "python3-pip"
    "python3-psutil"
    "xserver-xorg"
    "xinit"
    "x11-xserver-utils"
    "xdotool"
    "unclutter"
    "ca-certificates"
    "libnss3-tools"
)

# Check if we need X server (Lite vs Desktop)
if [ -n "$DISPLAY" ] || [ -d /usr/share/X11 ]; then
    echo "Desktop environment detected"
    # Remove xserver-xorg, xinit from list (already installed)
    PACKAGES=("${PACKAGES[@]/xserver-xorg/}")
    PACKAGES=("${PACKAGES[@]/xinit/}")
fi

echo "Installing: ${PACKAGES[@]}"
sudo apt-get install -y "${PACKAGES[@]}" 2>&1 | grep -v "is already the newest version" || true

# Verify psutil
if ! python3 -c "import psutil" 2>/dev/null; then
    echo "Installing psutil via pip..."
    sudo pip3 install psutil --break-system-packages 2>/dev/null || sudo pip3 install psutil
fi

echo -e "${GREEN}✓ Dependencies installed${NC}"

# Time sync
echo ""
echo "Configuring time sync..."
if systemctl list-unit-files | grep -q "systemd-timesyncd"; then
    sudo systemctl enable systemd-timesyncd 2>/dev/null || true
    sudo systemctl start systemd-timesyncd 2>/dev/null || true
    sudo timedatectl set-ntp true 2>/dev/null || true
else
    sudo apt-get install -y ntp 2>/dev/null || true
    sudo systemctl enable ntp 2>/dev/null || true
fi
echo "Current time: $(date)"

# Create directories
echo ""
echo "Creating directories..."
APP_DIR="/opt/piview"
CONFIG_DIR="$HOME/.piview"

sudo mkdir -p "$APP_DIR"
mkdir -p "$CONFIG_DIR"

# Install piview.py
sudo cp piview.py "$APP_DIR/"
sudo chmod +x "$APP_DIR/piview.py"
sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$APP_DIR"

echo -e "${GREEN}✓ Files installed to $APP_DIR${NC}"

# Configuration
echo ""
echo "=========================================================="
echo "Configuration"
echo "=========================================================="
echo ""

exec < /dev/tty
ask_tty "Dashboard URL" USER_URL "http://example.com"
ask_tty "Refresh interval (seconds)" REFRESH_INTERVAL "60"

# SSL handling
echo ""
echo "SSL Options:"
echo "  1) Ignore SSL errors (testing/self-signed certs)"
echo "  2) Use system certificates (production)"
ask_tty "Choose (1/2)" SSL_OPTION "1"

if [[ $SSL_OPTION == "1" ]]; then
    IGNORE_SSL="true"
    CERT_INSTALLED="false"
else
    IGNORE_SSL="false"
    CERT_INSTALLED="false"
fi

# Factory settings
echo ""
echo "Factory Settings:"
ask_tty "Watchdog freeze threshold (seconds)" WATCHDOG_THRESHOLD "120"
ask_tty "Auto-reboot after failures" AUTO_REBOOT_FAILURES "20"
ask_tty "Memory limit (MB)" MEMORY_LIMIT "1500"
ask_tty "Health endpoint port" HEALTH_PORT "8888"

# Create config
echo ""
echo "Creating configuration..."
cat > "$CONFIG_DIR/config.json" << EOF
{
  "url": "$USER_URL",
  "refresh_interval": $REFRESH_INTERVAL,
  "browser": "chromium-browser",
  "health_check_interval": 10,
  "max_browser_restarts": 10,
  "ignore_ssl_errors": $IGNORE_SSL,
  "cert_installed": $CERT_INSTALLED,
  "connection_retry_delay": 5,
  "max_connection_retries": 3,
  "watchdog_enabled": true,
  "watchdog_freeze_threshold": $WATCHDOG_THRESHOLD,
  "auto_reboot_enabled": true,
  "auto_reboot_after_failures": $AUTO_REBOOT_FAILURES,
  "memory_limit_mb": $MEMORY_LIMIT,
  "disk_space_warning_mb": 500,
  "log_rotation_size_mb": 10,
  "health_endpoint_port": $HEALTH_PORT,
  "kiosk_flags": [
    "--kiosk",
    "--noerrdialogs",
    "--disable-infobars",
    "--disable-session-crashed-bubble",
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--disable-gpu",
    "--user-data-dir=/tmp/chromium-piview"
  ]
}
EOF

echo -e "${GREEN}✓ Config: $CONFIG_DIR/config.json${NC}"

# Create helper scripts
echo ""
echo "Creating helper scripts..."

cat > "$APP_DIR/restart.sh" << 'EOF'
#!/bin/bash
sudo systemctl restart piview.service
echo "Piview restarted"
EOF

cat > "$APP_DIR/stop.sh" << 'EOF'
#!/bin/bash
sudo systemctl stop piview.service
pkill -9 chromium 2>/dev/null || true
pkill -9 chromium-browser 2>/dev/null || true
echo "Piview stopped"
EOF

cat > "$APP_DIR/status.sh" << 'EOF'
#!/bin/bash
echo "=== Service Status ==="
sudo systemctl status piview.service --no-pager -l
echo ""
echo "=== Health Status ==="
if [ -f /tmp/piview_health.json ]; then
    cat /tmp/piview_health.json | python3 -m json.tool 2>/dev/null || cat /tmp/piview_health.json
else
    echo "Health file not found"
fi
echo ""
echo "=== Recent Logs ==="
sudo journalctl -u piview.service -n 20 --no-pager
EOF

cat > "$APP_DIR/logs.sh" << 'EOF'
#!/bin/bash
# View live logs
sudo journalctl -u piview.service -f
EOF

sudo chmod +x "$APP_DIR"/*.sh

echo -e "${GREEN}✓ Helper scripts installed${NC}"

# Systemd service
echo ""
echo "Installing systemd service..."

sudo tee /etc/systemd/system/piview.service > /dev/null << EOF
[Unit]
Description=Piview Factory Kiosk - Bulletproof Display
After=network-online.target graphical.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$ACTUAL_USER
Group=$ACTUAL_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/python3 $APP_DIR/piview.py
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$ACTUAL_USER/.Xauthority

# Factory hardening
Restart=always
RestartSec=10

# Resource limits
MemoryMax=2G
MemoryHigh=1.5G
CPUQuota=200%
TasksMax=100

# Watchdog
WatchdogSec=180

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=piview

# Security
NoNewPrivileges=true
PrivateTmp=true

# Never give up
StartLimitBurst=999999

[Install]
WantedBy=graphical.target
EOF

# Screen blanking prevention
sudo tee /etc/systemd/system/disable-screen-blanking.service > /dev/null << 'EOF'
[Unit]
Description=Disable Screen Blanking
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > /sys/module/kernel/parameters/consoleblank'

[Install]
WantedBy=sysinit.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable disable-screen-blanking.service
sudo systemctl enable piview.service

echo -e "${GREEN}✓ Services configured${NC}"

# Disable sleep/suspend (Pi only)
if [ "$IS_PI" = true ]; then
    echo ""
    echo "Disabling sleep/suspend..."
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
fi

# Kernel parameters (Pi only)
if [ "$IS_PI" = true ] && [ -f /boot/cmdline.txt ]; then
    echo "Configuring kernel parameters..."
    if ! grep -q "consoleblank=0" /boot/cmdline.txt; then
        sudo cp /boot/cmdline.txt /boot/cmdline.txt.backup
        sudo sed -i 's/$/ consoleblank=0/' /boot/cmdline.txt
    fi
fi

# Hardware watchdog (Pi only)
if [ "$IS_PI" = true ]; then
    echo ""
    exec < /dev/tty
    ask_tty_yn "Enable hardware watchdog?" WATCHDOG_REPLY "y"
    if [[ $WATCHDOG_REPLY =~ ^[Yy]$ ]]; then
        echo "Installing hardware watchdog..."
        sudo apt-get install -y watchdog 2>/dev/null || true
        
        if [ -f /boot/config.txt ]; then
            if ! grep -q "^dtparam=watchdog=on" /boot/config.txt; then
                echo "dtparam=watchdog=on" | sudo tee -a /boot/config.txt > /dev/null
            fi
        fi
        
        if [ -f /etc/watchdog.conf ]; then
            sudo sed -i 's/^#watchdog-device/watchdog-device/' /etc/watchdog.conf 2>/dev/null || true
            if ! grep -q "^watchdog-device" /etc/watchdog.conf; then
                echo "watchdog-device = /dev/watchdog" | sudo tee -a /etc/watchdog.conf > /dev/null
            fi
        fi
        
        sudo systemctl enable watchdog 2>/dev/null || true
        echo -e "${GREEN}✓ Hardware watchdog enabled${NC}"
    fi
fi

# Auto-login
echo ""
exec < /dev/tty
ask_tty_yn "Enable auto-login?" AUTOLOGIN_REPLY "y"
if [[ $AUTOLOGIN_REPLY =~ ^[Yy]$ ]]; then
    sudo raspi-config nonint do_boot_behaviour B4 2>/dev/null || true
    echo -e "${GREEN}✓ Auto-login enabled${NC}"
fi

# Firewall
if command -v ufw &> /dev/null; then
    echo ""
    exec < /dev/tty
    ask_tty_yn "Open firewall port $HEALTH_PORT for monitoring?" FIREWALL_REPLY "y"
    if [[ $FIREWALL_REPLY =~ ^[Yy]$ ]]; then
        sudo ufw allow $HEALTH_PORT/tcp comment "Piview health" 2>/dev/null || true
        echo -e "${GREEN}✓ Firewall configured${NC}"
    fi
fi

# Read-only filesystem toggle
echo ""
echo "Creating read-only toggle script..."
sudo tee /usr/local/bin/overlayroot.sh > /dev/null << 'OVEREOF'
#!/bin/bash
# Toggle read-only filesystem

if [ "$1" = "enable" ]; then
    echo "Enabling read-only mode..."
    sudo mount -o remount,ro / 2>/dev/null || true
    sudo mount -o remount,ro /boot 2>/dev/null || true
    
    if [ -f /boot/cmdline.txt ]; then
        sudo cp /boot/cmdline.txt /boot/cmdline.txt.backup
        if ! grep -q "fastboot noswap" /boot/cmdline.txt; then
            sudo sed -i 's/$/ fastboot noswap/' /boot/cmdline.txt
        fi
    fi
    
    sudo cp /etc/fstab /etc/fstab.backup 2>/dev/null || true
    sudo sed -i 's/vfat\s*defaults/vfat defaults,ro/' /etc/fstab 2>/dev/null || true
    sudo sed -i 's/ext4\s*defaults/ext4 defaults,ro/' /etc/fstab 2>/dev/null || true
    
    echo "Read-only enabled. Reboot to apply."
    
elif [ "$1" = "disable" ]; then
    echo "Disabling read-only mode..."
    sudo mount -o remount,rw / 2>/dev/null || true
    sudo mount -o remount,rw /boot 2>/dev/null || true
    
    if [ -f /boot/cmdline.txt.backup ]; then
        sudo cp /boot/cmdline.txt.backup /boot/cmdline.txt
    fi
    if [ -f /etc/fstab.backup ]; then
        sudo cp /etc/fstab.backup /etc/fstab
    fi
    
    echo "Read-only disabled. Filesystem writable."
    
elif [ "$1" = "status" ]; then
    ROOT=$(findmnt -n -o OPTIONS / | grep -o ro || echo "")
    [ -n "$ROOT" ] && echo "Read-only: ENABLED" || echo "Read-only: DISABLED"
else
    echo "Usage: overlayroot.sh {enable|disable|status}"
fi
OVEREOF
sudo chmod +x /usr/local/bin/overlayroot.sh

# Create logs
sudo mkdir -p /var/log
sudo touch /var/log/piview.log
sudo chmod 666 /var/log/piview.log

# Summary
echo ""
echo "=========================================================="
echo -e "${GREEN}Setup Complete!${NC}"
echo "=========================================================="
echo ""
echo "Configuration: $CONFIG_DIR/config.json"
echo "URL: $USER_URL"
echo "Health: http://$(hostname -I | awk '{print $1}'):$HEALTH_PORT/health"
echo ""
echo "Commands:"
echo "  sudo systemctl start piview   - Start now"
echo "  sudo /opt/piview/restart.sh   - Restart"
echo "  sudo /opt/piview/status.sh    - Check status"
echo "  sudo /opt/piview/logs.sh      - View live logs"
echo ""
echo "Factory Features:"
echo "  ✓ Watchdog (${WATCHDOG_THRESHOLD}s freeze threshold)"
echo "  ✓ Auto-reboot (after $AUTO_REBOOT_FAILURES failures)"
echo "  ✓ Memory monitoring (${MEMORY_LIMIT}MB limit)"
echo "  ✓ Health endpoint (port $HEALTH_PORT)"
echo "  ✓ Infinite restarts"
echo ""

# Offer to start
exec < /dev/tty
ask_tty_yn "Start Piview now?" START_REPLY "y"
if [[ $START_REPLY =~ ^[Yy]$ ]]; then
    sudo systemctl start piview
    sleep 3
    sudo systemctl status piview --no-pager || true
    echo ""
    echo -e "${GREEN}Piview is running!${NC}"
else
    echo "Start later: sudo systemctl start piview"
fi

# Read-only option
echo ""
exec < /dev/tty
ask_tty_yn "Enable read-only filesystem now?" READONLY_REPLY "n"
if [[ $READONLY_REPLY =~ ^[Yy]$ ]]; then
    sudo /usr/local/bin/overlayroot.sh enable
    echo "Reboot to apply: sudo reboot"
else
    echo "Enable later: sudo overlayroot.sh enable"
fi

echo ""
echo "=========================================================="
echo "Installation complete!"
echo "=========================================================="
