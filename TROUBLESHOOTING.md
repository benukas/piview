# Piview Troubleshooting Guide

## Quick Diagnostics

If Piview didn't start after reboot, run these commands in order:

### 1. Check Service Status

```bash
# Check if service is enabled and running
sudo systemctl status piview.service

# Check all Piview services
sudo systemctl status piview*
```

### 2. View Service Logs

```bash
# View recent service logs (most important!)
sudo journalctl -u piview.service -n 100 --no-pager

# Follow logs in real-time
sudo journalctl -u piview.service -f

# View logs since boot
sudo journalctl -u piview.service -b
```

### 3. View Application Logs

```bash
# View Piview application log file
sudo tail -f /var/log/piview.log

# Or view last 50 lines
sudo tail -n 50 /var/log/piview.log
```

### 4. Check if Service is Enabled

```bash
# Check if service is enabled to start on boot
sudo systemctl is-enabled piview.service

# If not enabled, enable it
sudo systemctl enable piview.service
sudo systemctl start piview.service
```

## Common Issues

### Service Not Starting

**Symptoms:** Service shows as "failed" or "inactive"

**Check:**
```bash
# Check service status
sudo systemctl status piview.service

# Check if X server is available (for Lite)
echo $DISPLAY

# Check if user has permission
whoami
```

**Fix:**
```bash
# Enable and start service
sudo systemctl enable piview.service
sudo systemctl start piview.service

# Check logs immediately
sudo journalctl -u piview.service -n 50
```

### Browser Not Opening

**Symptoms:** Service running but no browser window

**Check:**
```bash
# Check if Chromium is installed
which chromium-browser

# Check application logs
sudo tail -f /var/log/piview.log

# Check if browser process is running
ps aux | grep chromium
```

**Fix:**
```bash
# Install Chromium if missing
sudo apt-get install chromium-browser

# Restart service
sudo systemctl restart piview.service
```

### X Server Not Available (Lite)

**Symptoms:** "Cannot connect to X server" errors

**Check:**
```bash
# Check if X server is running
ps aux | grep X

# Check DISPLAY variable
echo $DISPLAY
```

**Fix:**
```bash
# For Lite, X server should start with service
# Check service logs for X server errors
sudo journalctl -u piview.service | grep -i x
```

### Desktop Environment (Not Starting)

**Symptoms:** On Desktop, nothing appears after login

**Check:**
```bash
# Check if autostart entry exists
ls -la ~/.config/autostart/piview.desktop

# Check if service is running
sudo systemctl status piview.service
```

**Fix:**
```bash
# Manually start Piview
python3 /opt/piview/piview.py

# Or restart service
sudo systemctl restart piview.service
```

## Manual Start (For Testing)

If service won't start, try running manually:

### For Lite (needs X server):
```bash
startx
```

### For Desktop (X already running):
```bash
python3 /opt/piview/piview.py
```

## All Log Locations

1. **Service logs (systemd):**
   ```bash
   sudo journalctl -u piview.service
   ```

2. **Application logs:**
   ```bash
   sudo tail -f /var/log/piview.log
   ```

3. **Screen keepalive logs:**
   ```bash
   sudo journalctl -u piview-keepalive.service
   ```

4. **All Piview logs:**
   ```bash
   sudo journalctl -u piview* -f
   ```

## Quick Fix Commands

```bash
# Restart everything
sudo systemctl restart piview.service
sudo systemctl restart piview-keepalive.service

# Check status of all services
sudo systemctl status piview* disable-screen-blanking.service

# View all recent errors
sudo journalctl -u piview* -p err -n 50

# Re-enable and start
sudo systemctl enable piview.service
sudo systemctl start piview.service
```

## Still Not Working?

1. Check configuration file:
   ```bash
   sudo cat /etc/piview/config.json
   ```

2. Verify Python script exists:
   ```bash
   ls -la /opt/piview/piview.py
   ```

3. Test Python script manually:
   ```bash
   sudo python3 /opt/piview/piview.py
   ```

4. Check system logs for errors:
   ```bash
   sudo dmesg | tail -50
   ```
