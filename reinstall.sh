#!/bin/bash
# Piview Reinstall Script
# Stops services, removes old installation, and reinstalls

set -e

echo "=========================================="
echo "Piview Reinstall"
echo "=========================================="
echo ""

# Stop services
echo "Stopping services..."
sudo systemctl stop piview.service 2>/dev/null || true
sudo systemctl stop piview-keepalive.service 2>/dev/null || true
sudo systemctl stop disable-screen-blanking.service 2>/dev/null || true

# Disable services
echo "Disabling services..."
sudo systemctl disable piview.service 2>/dev/null || true
sudo systemctl disable piview-keepalive.service 2>/dev/null || true

# Remove service files
echo "Removing service files..."
sudo rm -f /etc/systemd/system/piview.service
sudo rm -f /etc/systemd/system/piview-keepalive.service
sudo rm -f /etc/systemd/system/disable-screen-blanking.service

# Remove application files (but keep config)
echo "Removing application files..."
if [ -d /opt/piview ]; then
    sudo rm -rf /opt/piview
fi

# Reload systemd
sudo systemctl daemon-reload

echo ""
echo "Old installation removed."
echo ""
read -p "Reinstall now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -f setup.sh ]; then
        ./setup.sh
    else
        echo "Running one-line installer..."
        curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash
    fi
else
    echo "Reinstall cancelled. Run './setup.sh' or the one-line installer when ready."
fi
