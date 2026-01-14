#!/bin/bash
# Standalone screen keepalive script
# Runs as a backup to prevent screen blanking

while true; do
    sleep 30
    
    # Disable screen blanking
    xset s off 2>/dev/null
    xset -dpms 2>/dev/null
    xset s noblank 2>/dev/null
    xset s reset 2>/dev/null
    
    # Move mouse slightly (invisible)
    xdotool mousemove_relative -- 1 0 2>/dev/null
    sleep 0.1
    xdotool mousemove_relative -- -1 0 2>/dev/null
    
    # Wake HDMI
    tvservice -p 2>/dev/null || true
    
    # Console blanking
    setterm -blank 0 -powerdown 0 2>/dev/null || true
done
