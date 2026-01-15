#!/bin/bash
# Piview Reinstall Script
# Two-phase process:
# Phase 1: Kill everything, disable read-only, ask for reboot
# Phase 2: After reboot, verify read-only is disabled, then install

set -e

echo "=========================================="
echo "Piview Reinstall (Two-Phase Process)"
echo "=========================================="
echo ""

# Check if this is Phase 2 (after reboot)
# We'll create a marker file during Phase 1
PHASE2_MARKER="/tmp/piview-reinstall-phase2"

if [ -f "$PHASE2_MARKER" ]; then
    echo "Phase 2: Post-reboot verification and installation"
    echo ""
    
    # Remove marker
    rm -f "$PHASE2_MARKER"
    
    # Verify read-only is disabled
    ROOT=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -o ro || echo "")
    BOOT=$(findmnt -n -o OPTIONS /boot 2>/dev/null | grep -o ro || echo "")
    
    if [ -n "$ROOT" ] || [ -n "$BOOT" ]; then
        echo "⚠️  ERROR: Read-only mode is still ENABLED after reboot"
        echo ""
        echo "Please manually disable it:"
        echo "  sudo overlayroot.sh disable"
        echo "  sudo reboot"
        echo ""
        exit 1
    fi
    
    # Check cmdline.txt and fstab
    if [ -f /boot/cmdline.txt ] && grep -q "fastboot noswap" /boot/cmdline.txt 2>/dev/null; then
        echo "⚠️  WARNING: Read-only flags still in /boot/cmdline.txt"
        echo "   Attempting to remove..."
        if [ -f /boot/cmdline.txt.backup ]; then
            sudo cp /boot/cmdline.txt.backup /boot/cmdline.txt
        else
            sudo sed -i 's/ fastboot noswap//' /boot/cmdline.txt 2>/dev/null || true
        fi
    fi
    
    if [ -f /etc/fstab ] && grep -q "defaults,ro" /etc/fstab 2>/dev/null; then
        echo "⚠️  WARNING: Read-only flags still in /etc/fstab"
        echo "   Attempting to remove..."
        if [ -f /etc/fstab.backup ]; then
            sudo cp /etc/fstab.backup /etc/fstab
        else
            sudo sed -i 's/vfat defaults,ro/vfat defaults/' /etc/fstab 2>/dev/null || true
            sudo sed -i 's/ext4 defaults,ro/ext4 defaults/' /etc/fstab 2>/dev/null || true
        fi
    fi
    
    echo "✓ Read-only mode verified as disabled"
    echo ""
    echo "=========================================="
    echo "Starting fresh installation..."
    echo "=========================================="
    echo ""
    
    # Reinstall
    if [ -f setup.sh ]; then
        chmod +x setup.sh
        ./setup.sh
    else
        echo "Running one-line installer..."
        curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash
    fi
    
else
    # Phase 1: Uninstall and disable read-only
    echo "Phase 1: Uninstalling and disabling read-only mode"
    echo ""
    echo "This will:"
    echo "  1. Kill all Piview processes and services"
    echo "  2. Remove all Piview files"
    echo "  3. Disable read-only filesystem protection"
    echo "  4. Ask you to reboot"
    echo ""
    echo "After reboot, run this script again to complete installation."
    echo ""
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    
    # Run uninstall script first
    if [ -f uninstall.sh ]; then
        echo ""
        echo "Running uninstall..."
        chmod +x uninstall.sh
        ./uninstall.sh
        
        # Create marker for Phase 2
        touch "$PHASE2_MARKER"
        echo ""
        echo "=========================================="
        echo "Phase 1 Complete"
        echo "=========================================="
        echo ""
        echo "⚠️  IMPORTANT: After reboot, run this script again:"
        echo "   ./reinstall.sh"
        echo ""
        echo "Or if you downloaded from GitHub:"
        echo "   curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash"
        echo ""
    else
        echo "⚠️  ERROR: uninstall.sh not found"
        echo "   Please run uninstall.sh manually first"
        exit 1
    fi
fi
