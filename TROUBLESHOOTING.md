# Piview Troubleshooting

## Quick Check

If nothing appears after reboot:

```bash
# Check service status
sudo systemctl status piview.service

# View logs
sudo journalctl -u piview.service -n 50

# Export all logs (for sharing)
piview-export-logs
```

## Quick Fix

```bash
# Enable and start service
sudo systemctl enable piview.service
sudo systemctl start piview.service

# Check it's running
sudo systemctl status piview.service
```

## Manual Start (Testing)

```bash
# For Desktop/VirtualBox
DISPLAY=:0 python3 /opt/piview/piview.py

# For Lite
startx
```

That's it. If it still doesn't work, export logs with `piview-export-logs` and check the generated file.
