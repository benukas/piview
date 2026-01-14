#!/bin/bash
# Piview Log Export Script
# Exports all Piview logs to a single file for easy sharing/debugging

OUTPUT_FILE="piview_logs_$(date +%Y%m%d_%H%M%S).txt"

echo "Exporting Piview logs..."
echo "Output file: $OUTPUT_FILE"
echo ""

{
    echo "=========================================="
    echo "Piview Log Export"
    echo "Generated: $(date)"
    echo "=========================================="
    echo ""
    
    echo "=========================================="
    echo "System Information"
    echo "=========================================="
    uname -a
    echo ""
    cat /etc/os-release 2>/dev/null || echo "OS release not available"
    echo ""
    
    echo "=========================================="
    echo "Service Status"
    echo "=========================================="
    sudo systemctl status piview.service --no-pager -l || echo "Service status unavailable"
    echo ""
    sudo systemctl status piview-keepalive.service --no-pager -l 2>/dev/null || echo "Keepalive service status unavailable"
    echo ""
    
    echo "=========================================="
    echo "Service Logs (Last 200 lines)"
    echo "=========================================="
    sudo journalctl -u piview.service -n 200 --no-pager || echo "Service logs unavailable"
    echo ""
    
    echo "=========================================="
    echo "Application Log File"
    echo "=========================================="
    if [ -f /var/log/piview.log ]; then
        sudo tail -n 500 /var/log/piview.log || echo "Could not read application log"
    else
        echo "Application log file not found: /var/log/piview.log"
    fi
    echo ""
    
    echo "=========================================="
    echo "Screen Keepalive Service Logs"
    echo "=========================================="
    sudo journalctl -u piview-keepalive.service -n 100 --no-pager 2>/dev/null || echo "Keepalive logs unavailable"
    echo ""
    
    echo "=========================================="
    echo "All Piview Service Logs (Recent)"
    echo "=========================================="
    sudo journalctl -u piview* -n 100 --no-pager || echo "Piview service logs unavailable"
    echo ""
    
    echo "=========================================="
    echo "Configuration"
    echo "=========================================="
    if [ -f /etc/piview/config.json ]; then
        sudo cat /etc/piview/config.json
    else
        echo "Configuration file not found: /etc/piview/config.json"
    fi
    echo ""
    
    echo "=========================================="
    echo "Running Processes"
    echo "=========================================="
    ps aux | grep -E "(piview|chromium)" | grep -v grep || echo "No Piview/Chromium processes found"
    echo ""
    
    echo "=========================================="
    echo "X Server Status"
    echo "=========================================="
    echo "DISPLAY: $DISPLAY"
    xset q 2>/dev/null || echo "X server not accessible"
    echo ""
    
    echo "=========================================="
    echo "Network Status"
    echo "=========================================="
    ip addr show 2>/dev/null || ifconfig 2>/dev/null || echo "Network info unavailable"
    echo ""
    
    echo "=========================================="
    echo "System Errors (dmesg - last 50)"
    echo "=========================================="
    sudo dmesg | tail -50 || echo "dmesg unavailable"
    echo ""
    
    echo "=========================================="
    echo "End of Log Export"
    echo "=========================================="
    
} > "$OUTPUT_FILE" 2>&1

echo "Logs exported to: $OUTPUT_FILE"
echo ""
echo "To view: cat $OUTPUT_FILE"
echo "To copy from VirtualBox:"
echo "  1. Enable shared folder in VirtualBox"
echo "  2. Or use SCP: scp user@ip:$OUTPUT_FILE ."
echo "  3. Or copy via VirtualBox guest additions clipboard"
