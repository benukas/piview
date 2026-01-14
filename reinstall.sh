#!/bin/bash
# Piview Reinstall Script
# Aggressively stops ALL services, processes, and autostarts, then reinstalls

set -e

echo "=========================================="
echo "Piview Complete Reinstall"
echo "=========================================="
echo ""

# Kill ALL browser processes first (most important - stops the website from opening)
echo "Killing all browser processes..."
sudo pkill -9 chromium 2>/dev/null || true
sudo pkill -9 chromium-browser 2>/dev/null || true
sudo pkill -9 chrome 2>/dev/null || true
sudo pkill -9 google-chrome 2>/dev/null || true
sleep 1

# Kill ALL piview Python processes
echo "Killing all Piview Python processes..."
sudo pkill -9 -f piview.py 2>/dev/null || true
sudo pkill -9 -f "python.*piview" 2>/dev/null || true
sleep 1

# Kill any X server processes related to piview
echo "Killing X server processes..."
sudo pkill -9 -f "startx.*piview" 2>/dev/null || true
sudo pkill -9 -f "xinit.*piview" 2>/dev/null || true
sleep 1

# Stop and disable ALL services
echo "Stopping and disabling all services..."
sudo systemctl stop piview.service 2>/dev/null || true
sudo systemctl stop piview-keepalive.service 2>/dev/null || true
sudo systemctl stop disable-screen-blanking.service 2>/dev/null || true
sleep 1

sudo systemctl disable piview.service 2>/dev/null || true
sudo systemctl disable piview-keepalive.service 2>/dev/null || true
sudo systemctl disable disable-screen-blanking.service 2>/dev/null || true

# Remove service files
echo "Removing service files..."
sudo rm -f /etc/systemd/system/piview.service
sudo rm -f /etc/systemd/system/piview-keepalive.service
sudo rm -f /etc/systemd/system/disable-screen-blanking.service

# Remove autostart entries (Desktop environment)
echo "Removing autostart entries..."
rm -f ~/.config/autostart/piview.desktop 2>/dev/null || true
rm -f ~/.config/autostart/piview*.desktop 2>/dev/null || true

# Remove .xinitrc (Lite/headless environment)
echo "Removing .xinitrc configuration..."
if [ -f ~/.xinitrc ]; then
    # Only remove if it contains piview
    if grep -q "piview" ~/.xinitrc 2>/dev/null; then
        # Backup original if it exists and isn't ours
        if [ ! -f ~/.xinitrc.backup ]; then
            cp ~/.xinitrc ~/.xinitrc.backup 2>/dev/null || true
        fi
        # Remove piview-specific .xinitrc
        rm -f ~/.xinitrc 2>/dev/null || true
    fi
fi

# Kill any remaining background processes
echo "Killing remaining background processes..."
sudo pkill -9 -f "screen_keepalive" 2>/dev/null || true
sudo pkill -9 -f "unclutter" 2>/dev/null || true
sleep 1

# Remove application files (but keep config for reference)
echo "Removing application files..."
if [ -d /opt/piview ]; then
    sudo rm -rf /opt/piview
fi

# Remove symlinks
echo "Removing symlinks..."
sudo rm -f /usr/local/bin/piview-export-logs 2>/dev/null || true

# Reload systemd to apply changes
echo "Reloading systemd..."
sudo systemctl daemon-reload
sudo systemctl reset-failed 2>/dev/null || true

# Final verification - kill any stragglers
echo "Final cleanup..."
sleep 2
sudo pkill -9 chromium 2>/dev/null || true
sudo pkill -9 chromium-browser 2>/dev/null || true
sudo pkill -9 -f piview.py 2>/dev/null || true

echo ""
echo "=========================================="
echo "All Piview processes and services stopped"
echo "=========================================="
echo ""
echo "Removed:"
echo "  ✓ All browser processes"
echo "  ✓ All Piview Python processes"
echo "  ✓ All systemd services"
echo "  ✓ Autostart entries"
echo "  ✓ .xinitrc configuration"
echo "  ✓ Application files"
echo ""
echo "Configuration file preserved at: /etc/piview/config.json"
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
    echo ""
    echo "To verify everything is stopped, run:"
    echo "  ps aux | grep -i piview"
    echo "  ps aux | grep -i chromium"
    echo "  sudo systemctl status piview.service"
fi
