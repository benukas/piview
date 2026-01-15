#!/bin/bash
# Emergency script to disable read-only mode
# Run this if read-only mode broke your system

set -e

echo "=========================================="
echo "Piview - Disable Read-Only Mode"
echo "=========================================="
echo ""

# Try to remount as read-write first
echo "Attempting to remount filesystem as read-write..."
sudo mount -o remount,rw / 2>/dev/null || {
    echo "Warning: Could not remount root as read-write"
    echo "You may need to boot from recovery mode or use a live USB"
}

sudo mount -o remount,rw /boot 2>/dev/null || {
    echo "Warning: Could not remount /boot as read-write"
}

# If overlayroot.sh exists, use it
if [ -f /usr/local/bin/overlayroot.sh ]; then
    echo "Using overlayroot.sh to disable read-only mode..."
    sudo /usr/local/bin/overlayroot.sh disable
else
    echo "overlayroot.sh not found, manually restoring files..."
    
    # Restore cmdline.txt
    if [ -f /boot/cmdline.txt.backup ]; then
        echo "Restoring /boot/cmdline.txt from backup..."
        sudo cp /boot/cmdline.txt.backup /boot/cmdline.txt
    else
        echo "Removing read-only flags from /boot/cmdline.txt..."
        sudo sed -i 's/ fastboot noswap//' /boot/cmdline.txt 2>/dev/null || true
    fi
    
    # Restore fstab
    if [ -f /etc/fstab.backup ]; then
        echo "Restoring /etc/fstab from backup..."
        sudo cp /etc/fstab.backup /etc/fstab
    else
        echo "Removing read-only flags from /etc/fstab..."
        sudo sed -i 's/vfat defaults,ro/vfat defaults/' /etc/fstab 2>/dev/null || true
        sudo sed -i 's/ext4 defaults,ro/ext4 defaults/' /etc/fstab 2>/dev/null || true
    fi
fi

echo ""
echo "=========================================="
echo "Read-only mode disabled!"
echo "=========================================="
echo ""
echo "IMPORTANT: You MUST reboot for changes to take full effect:"
echo "  sudo reboot"
echo ""
echo "After reboot, the filesystem will be writable again."
echo ""
