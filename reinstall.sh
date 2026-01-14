#!/bin/bash
# Piview Reinstall Script
# Runs uninstall first, then reinstalls

set -e

echo "=========================================="
echo "Piview Reinstall"
echo "=========================================="
echo ""

# Run uninstall script first
if [ -f uninstall.sh ]; then
    echo "Running uninstall first..."
    chmod +x uninstall.sh
    ./uninstall.sh
else
    echo "Warning: uninstall.sh not found, skipping cleanup step"
fi

echo ""
echo "=========================================="
echo "Starting fresh installation..."
echo "=========================================="
echo ""

# Reinstall
if [ -f setup.sh ]; then
    ./setup.sh
else
    echo "Running one-line installer..."
    curl -sSL https://raw.githubusercontent.com/benukas/piview/main/install.sh | bash
fi
