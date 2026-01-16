#!/usr/bin/env python3
"""
Piview - Simple & Reliable Raspberry Pi Kiosk
Zero-config deployment with optional hardening for industrial use
"""

import json
import time
import subprocess
import os
import sys
import signal
import threading
import logging
import urllib.request
import ssl
import shutil
import psutil
from pathlib import Path
from datetime import datetime

CONFIG_FILE = Path("/etc/piview/config.json")
USER_CONFIG_FILE = Path.home() / ".piview" / "config.json"
LOG_FILE = Path("/var/log/piview.log")
HEALTH_FILE = Path("/tmp/piview_health.json")

DEFAULT_CONFIG = {
    "url": "http://example.com",
    "refresh_interval": 60,
    "browser": "chromium-browser",
    
    # Safety levels: "minimal", "standard", "paranoid"
    "safety_level": "standard",
    
    # Standard monitoring
    "health_check_interval": 30,
    "max_browser_restarts_per_hour": 10,
    "ignore_ssl_errors": True,
    
    # Watchdog settings (applied based on safety_level)
    "watchdog_enabled": True,
    "watchdog_freeze_threshold": 300,  # 5 minutes
    "watchdog_check_interval": 60,     # Check every minute
    
    # Memory management
    "memory_limit_enabled": True,
    "memory_limit_mb": 1500,
    
    # Auto-reboot (paranoid only)
    "auto_reboot_enabled": False,
    "auto_reboot_after_failures": 50,
    
    # Monitoring endpoint
    "health_endpoint_enabled": True,
    "health_endpoint_port": 8888,
    
    # Disk management
    "disk_cleanup_enabled": True,
    "disk_space_warning_mb": 500,
    
    # Logging
    "log_rotation_size_mb": 10,
    
    # Browser flags (auto-configured)
    "kiosk_flags": []
}

# Safety level presets
SAFETY_PRESETS = {
    "minimal": {
        "watchdog_enabled": False,
        "memory_limit_enabled": False,
        "auto_reboot_enabled": False,
        "health_endpoint_enabled": False,
        "disk_cleanup_enabled": False,
        "health_check_interval": 60,
    },
    "standard": {
        "watchdog_enabled": True,
        "watchdog_freeze_threshold": 300,
        "watchdog_check_interval": 60,
        "memory_limit_enabled": True,
        "auto_reboot_enabled": False,
        "health_endpoint_enabled": True,
        "disk_cleanup_enabled": True,
        "health_check_interval": 30,
    },
    "paranoid": {
        "watchdog_enabled": True,
        "watchdog_freeze_threshold": 180,
        "watchdog_check_interval": 30,
        "memory_limit_enabled": True,
        "auto_reboot_enabled": True,
        "auto_reboot_after_failures": 50,
        "health_endpoint_enabled": True,
        "disk_cleanup_enabled": True,
        "health_check_interval": 15,
    }
}

class Piview:
    def __init__(self):
        self.logger = None
        self.running = True
        self.browser_process = None
        self.browser_launch_time = 0
        self.browser_restarts = []  # Timestamps for rate limiting
        self.consecutive_failures = 0
        self.total_uptime_start = time.time()
        
        # Metrics
        self.metrics = {
            "browser_restarts": 0,
            "network_failures": 0,
            "memory_warnings": 0,
            "watchdog_kills": 0,
            "uptime_seconds": 0,
            "last_error": None,
            "last_health_check": 0
        }
        
        self.setup_x_environment()
        self.setup_logging()
        self.config = self.load_config()
        self.apply_safety_preset()
        
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        self.prevent_screen_blanking()
        self.start_background_threads()
        self.write_health_status()
    
    def apply_safety_preset(self):
        """Apply safety level preset"""
        safety_level = self.config.get("safety_level", "standard")
        if safety_level in SAFETY_PRESETS:
            preset = SAFETY_PRESETS[safety_level]
            # Apply preset values if not explicitly set in config
            # (preserve explicit config values over preset defaults)
            for key, value in preset.items():
                if key not in self.config:
                    self.config[key] = value
            self.log(f"Safety level: {safety_level}")
    
    def setup_x_environment(self):
        """Setup X server environment"""
        display = os.environ.get('DISPLAY', ':0')
        os.environ['DISPLAY'] = display
        
        if 'XAUTHORITY' not in os.environ:
            try:
                import pwd
                username = pwd.getpwuid(os.getuid()).pw_name
            except Exception:
                username = os.environ.get('USER', 'pi')
            
            xauth_paths = [
                f"/home/{username}/.Xauthority",
                os.path.expanduser("~/.Xauthority"),
                "/root/.Xauthority"
            ]
            
            for xauth_path in xauth_paths:
                if os.path.exists(xauth_path):
                    os.environ['XAUTHORITY'] = xauth_path
                    break
    
    def setup_logging(self):
        """Setup logging with rotation"""
        try:
            LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            
            # Rotate log if too large
            if LOG_FILE.exists():
                size_mb = LOG_FILE.stat().st_size / (1024 * 1024)
                max_size = self.config.get("log_rotation_size_mb", 10) if hasattr(self, 'config') else 10
                if size_mb > max_size:
                    backup = LOG_FILE.with_suffix('.log.old')
                    if backup.exists():
                        backup.unlink()
                    LOG_FILE.rename(backup)
            
            file_handler = logging.FileHandler(LOG_FILE)
            file_handler.setLevel(logging.INFO)
            file_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
            
            console_handler = logging.StreamHandler(sys.stdout)
            console_handler.setLevel(logging.INFO)
            console_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
            
            self.logger = logging.getLogger(__name__)
            self.logger.setLevel(logging.INFO)
            self.logger.handlers.clear()
            self.logger.addHandler(file_handler)
            self.logger.addHandler(console_handler)
            
        except Exception as e:
            print(f"Logging setup failed: {e}", file=sys.stderr)
            self.logger = None
    
    def log(self, message, level='info'):
        """Log with metrics update"""
        if self.logger:
            if level == 'error':
                self.logger.error(message)
                self.metrics["last_error"] = f"{datetime.now()}: {message}"
            elif level == 'warning':
                self.logger.warning(message)
            else:
                self.logger.info(message)
        else:
            print(f"[{datetime.now()}] {message}")
    
    def write_health_status(self):
        """Write health status for monitoring"""
        try:
            self.metrics["uptime_seconds"] = int(time.time() - self.total_uptime_start)
            self.metrics["last_health_check"] = time.time()
            
            status = "healthy"
            if self.consecutive_failures >= 10:
                status = "degraded"
            elif self.consecutive_failures >= 25:
                status = "critical"
            
            health = {
                "status": status,
                "browser_running": self.browser_process is not None and self.browser_process.poll() is None,
                "safety_level": self.config.get("safety_level", "standard"),
                "metrics": self.metrics,
                "consecutive_failures": self.consecutive_failures,
                "timestamp": datetime.now().isoformat()
            }
            
            with open(HEALTH_FILE, 'w') as f:
                json.dump(health, f, indent=2)
        except Exception:
            pass
    
    def is_browser_responsive(self):
        """Simple responsiveness check"""
        if not self.browser_process or self.browser_process.poll() is not None:
            return False
        
        # Just started? Give it time
        if time.time() - self.browser_launch_time < 30:
            return True
        
        try:
            # Check if process exists and has memory (means it's alive)
            process = psutil.Process(self.browser_process.pid)
            mem_mb = process.memory_info().rss / (1024 * 1024)
            
            # If browser has memory allocated, consider it responsive
            # (even if idle - we're not being aggressive here)
            return mem_mb > 50
            
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            return False
        except Exception:
            return True  # Benefit of doubt
    
    def check_memory_limit(self):
        """Check and enforce memory limit"""
        if not self.config.get("memory_limit_enabled", True):
            return
        
        if not self.browser_process:
            return
        
        try:
            process = psutil.Process(self.browser_process.pid)
            memory_mb = process.memory_info().rss / (1024 * 1024)
            
            limit = self.config.get("memory_limit_mb", 1500)
            if memory_mb > limit:
                self.log(f"Memory limit exceeded: {memory_mb:.0f}MB > {limit}MB - restarting", 'warning')
                self.metrics["memory_warnings"] += 1
                self.restart_browser()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
        except Exception as e:
            self.log(f"Memory check error: {e}", 'warning')
    
    def cleanup_if_needed(self):
        """Clean up disk space if needed"""
        if not self.config.get("disk_cleanup_enabled", True):
            return
        
        try:
            disk = shutil.disk_usage("/")
            free_mb = disk.free / (1024 * 1024)
            warning_threshold = self.config.get("disk_space_warning_mb", 500)
            
            if free_mb < warning_threshold:
                self.log(f"Low disk space: {free_mb:.0f}MB - cleaning up", 'warning')
                
                # Clean browser cache
                cache_dir = Path("/tmp/chromium-piview")
                if cache_dir.exists():
                    shutil.rmtree(cache_dir, ignore_errors=True)
                
                # Keep only last log
                log_dir = LOG_FILE.parent
                if log_dir.exists():
                    old_logs = sorted(log_dir.glob("*.log.old*"))
                    for old_log in old_logs[1:]:
                        old_log.unlink()
        except Exception as e:
            self.log(f"Cleanup error: {e}", 'warning')
    
    def watchdog_thread(self):
        """Simple watchdog - just checks if browser is frozen"""
        if not self.config.get("watchdog_enabled", True):
            return
        
        freeze_threshold = self.config.get("watchdog_freeze_threshold", 300)
        check_interval = self.config.get("watchdog_check_interval", 60)
        
        checks_needed = max(3, freeze_threshold // check_interval)
        consecutive_unresponsive = 0
        
        self.log(f"Watchdog active: {checks_needed} failed checks ({freeze_threshold}s) = kill")
        
        while self.running:
            time.sleep(check_interval)
            
            if not self.config.get("watchdog_enabled", True):
                continue
            
            try:
                is_responsive = self.is_browser_responsive()
                
                if is_responsive:
                    consecutive_unresponsive = 0
                else:
                    consecutive_unresponsive += 1
                    
                    if consecutive_unresponsive >= checks_needed:
                        elapsed = consecutive_unresponsive * check_interval
                        self.log(f"Watchdog: Browser frozen for {elapsed}s - killing", 'error')
                        self.metrics["watchdog_kills"] += 1
                        self.consecutive_failures += 1
                        
                        # Kill it
                        try:
                            if self.browser_process:
                                self.browser_process.kill()
                            subprocess.run(["pkill", "-9", "-f", "chromium|firefox"],
                                         timeout=2, check=False,
                                         stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
                        except Exception:
                            pass
                        
                        consecutive_unresponsive = 0
                        self.check_emergency_reboot()
            except Exception as e:
                self.log(f"Watchdog error: {e}", 'warning')
    
    def check_emergency_reboot(self):
        """Reboot if failures are catastrophic (paranoid mode only)"""
        if not self.config.get("auto_reboot_enabled", False):
            return
        
        max_failures = self.config.get("auto_reboot_after_failures", 50)
        if self.consecutive_failures >= max_failures:
            self.log(f"EMERGENCY: {self.consecutive_failures} failures - REBOOTING", 'error')
            self.write_health_status()
            time.sleep(2)
            try:
                subprocess.run(["sudo", "reboot"], timeout=5)
            except Exception:
                subprocess.run(["reboot"], timeout=5, check=False)
    
    def health_check_thread(self):
        """Periodic health monitoring"""
        while self.running:
            try:
                interval = self.config.get("health_check_interval", 30)
                time.sleep(interval)
                
                # Check if browser died
                if self.browser_process and self.browser_process.poll() is not None:
                    elapsed = time.time() - self.browser_launch_time
                    if elapsed >= 10:  # Only care if it ran for a bit
                        self.log("Browser died unexpectedly", 'warning')
                        self.consecutive_failures += 1
                        self.restart_browser()
                
                # Check memory limit
                self.check_memory_limit()
                
                # Clean up if needed
                self.cleanup_if_needed()
                
                # Update health file
                self.write_health_status()
                
                # Check for emergency reboot
                self.check_emergency_reboot()
                
            except Exception as e:
                self.log(f"Health check error: {e}", 'warning')
    
    def health_endpoint_thread(self):
        """HTTP endpoint for monitoring"""
        if not self.config.get("health_endpoint_enabled", True):
            return
        
        try:
            from http.server import HTTPServer, BaseHTTPRequestHandler
            
            class HealthHandler(BaseHTTPRequestHandler):
                def do_GET(handler_self):
                    if handler_self.path == '/health':
                        try:
                            with open(HEALTH_FILE, 'r') as f:
                                health_data = f.read()
                            handler_self.send_response(200)
                            handler_self.send_header('Content-Type', 'application/json')
                            handler_self.end_headers()
                            handler_self.wfile.write(health_data.encode())
                        except Exception:
                            handler_self.send_response(500)
                            handler_self.end_headers()
                    else:
                        handler_self.send_response(404)
                        handler_self.end_headers()
                
                def log_message(handler_self, format, *args):
                    pass
            
            port = self.config.get("health_endpoint_port", 8888)
            server = HTTPServer(('0.0.0.0', port), HealthHandler)
            self.log(f"Health endpoint on port {port}")
            server.serve_forever()
        except Exception as e:
            self.log(f"Health endpoint error: {e}", 'warning')
    
    def screen_keepalive_thread(self):
        """Keep screen alive"""
        while self.running:
            try:
                time.sleep(30)
                self.prevent_screen_blanking()
                
                # Optional mouse jiggle if xdotool available
                if shutil.which("xdotool"):
                    try:
                        subprocess.run(["xdotool", "mousemove_relative", "--", "1", "0"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     timeout=1)
                        time.sleep(0.1)
                        subprocess.run(["xdotool", "mousemove_relative", "--", "-1", "0"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     timeout=1)
                    except Exception:
                        pass
            except Exception:
                pass
    
    def start_background_threads(self):
        """Start monitoring threads based on config"""
        threading.Thread(target=self.screen_keepalive_thread, daemon=True).start()
        threading.Thread(target=self.health_check_thread, daemon=True).start()
        
        if self.config.get("watchdog_enabled", True):
            threading.Thread(target=self.watchdog_thread, daemon=True).start()
        
        if self.config.get("health_endpoint_enabled", True):
            threading.Thread(target=self.health_endpoint_thread, daemon=True).start()
    
    def prevent_screen_blanking(self):
        """Prevent screen from sleeping"""
        try:
            subprocess.run(["xset", "s", "off", "-dpms", "s", "noblank"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         timeout=2)
        except Exception:
            pass
    
    def load_config(self):
        """Load configuration"""
        config_file = USER_CONFIG_FILE if USER_CONFIG_FILE.exists() else CONFIG_FILE
        
        if not config_file.exists():
            return DEFAULT_CONFIG.copy()
        
        try:
            with open(config_file, 'r') as f:
                config = json.load(f)
                merged = DEFAULT_CONFIG.copy()
                merged.update(config)
                return merged
        except Exception as e:
            self.log(f"Config load failed: {e}", 'warning')
            return DEFAULT_CONFIG.copy()
    
    def signal_handler(self, signum, frame):
        """Graceful shutdown"""
        self.log("Shutting down...")
        self.running = False
        self.close_browser()
        sys.exit(0)
    
    def close_browser(self):
        """Close browser"""
        if self.browser_process:
            try:
                self.browser_process.terminate()
                self.browser_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    self.browser_process.kill()
                except Exception:
                    pass
            except Exception:
                pass
            finally:
                self.browser_process = None
        
        # Cleanup any stragglers
        try:
            subprocess.run(["pkill", "-9", "-f", "chromium|firefox"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         timeout=2)
        except Exception:
            pass
    
    def create_loading_page(self, target_url):
        """Create temporary loading page"""
        js_url = target_url.replace('"', '\\"').replace("'", "\\'")
        
        loading_html = f"""<!DOCTYPE html>
<html>
<head>
    <title>Loading...</title>
    <meta http-equiv="refresh" content="10;url={target_url}">
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background: #000;
            color: #fff;
        }}
        .container {{
            text-align: center;
            padding: 40px;
        }}
        .spinner {{
            border: 4px solid #333;
            border-top: 4px solid #0066ff;
            border-radius: 50%;
            width: 60px;
            height: 60px;
            animation: spin 1s linear infinite;
            margin: 0 auto 30px;
        }}
        @keyframes spin {{
            0% {{ transform: rotate(0deg); }}
            100% {{ transform: rotate(360deg); }}
        }}
        h1 {{ color: #0066ff; margin-bottom: 20px; }}
        .url {{ color: #666; word-break: break-all; font-size: 14px; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="spinner"></div>
        <h1>Loading...</h1>
        <p class="url">{target_url}</p>
    </div>
    <script>
        setTimeout(function() {{
            window.location.href = "{js_url}";
        }}, 2000);
    </script>
</body>
</html>"""
        
        loading_file = Path("/tmp/piview_loading.html")
        loading_file.write_text(loading_html)
        return f"file://{loading_file}"
    
    def check_url_connectivity(self, url):
        """Quick connectivity check"""
        try:
            from urllib.parse import urlparse
            import socket
            
            parsed = urlparse(url)
            hostname = parsed.hostname
            if not hostname:
                return False
            
            # DNS check
            try:
                socket.gethostbyname(hostname)
            except socket.gaierror:
                self.log(f"DNS failed: {hostname}", 'error')
                self.metrics["network_failures"] += 1
                return False
            
            # HTTP check
            ssl_context = None
            if self.config.get("ignore_ssl_errors", True):
                ssl_context = ssl.create_default_context()
                ssl_context.check_hostname = False
                ssl_context.verify_mode = ssl.CERT_NONE
            
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10, context=ssl_context) as response:
                return response.status in [200, 301, 302, 303, 307, 308]
        except Exception:
            self.metrics["network_failures"] += 1
            return False
    
    def wait_for_x_server(self, max_wait=30):
        """Wait for X server to be ready"""
        for _ in range(max_wait):
            try:
                result = subprocess.run(["xset", "q"],
                                      stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL,
                                      timeout=2)
                if result.returncode == 0:
                    return True
            except Exception:
                pass
            time.sleep(1)
        return False
    
    def find_browser(self):
        """Find available browser"""
        browser_type = self.config.get("browser_type", "chromium")
        browser_cmd = self.config.get("browser", None)
        
        if browser_cmd and shutil.which(browser_cmd):
            return browser_cmd
        
        browsers = ["firefox", "firefox-esr"] if browser_type == "firefox" else ["chromium-browser", "chromium", "google-chrome"]
        
        for browser in browsers:
            if shutil.which(browser):
                return browser
        return None
    
    def can_restart_browser(self):
        """Check if we can restart (rate limiting)"""
        now = time.time()
        hour_ago = now - 3600
        
        # Clean old timestamps
        self.browser_restarts = [t for t in self.browser_restarts if t > hour_ago]
        
        # Check limit
        max_restarts = self.config.get("max_browser_restarts_per_hour", 10)
        if len(self.browser_restarts) >= max_restarts:
            self.log(f"Restart rate limit: {len(self.browser_restarts)}/{max_restarts} per hour", 'warning')
            return False
        
        return True
    
    def restart_browser(self):
        """Restart browser with rate limiting"""
        if not self.can_restart_browser():
            self.log("Waiting before restart (rate limited)...", 'warning')
            time.sleep(60)
            return
        
        self.metrics["browser_restarts"] += 1
        self.browser_restarts.append(time.time())
        
        self.close_browser()
        time.sleep(2)
        self.prevent_screen_blanking()
        
        if self.open_url(self.config["url"]):
            self.consecutive_failures = 0
        else:
            self.consecutive_failures += 1
    
    def open_url(self, url):
        """Open URL in browser"""
        self.close_browser()
        
        if not self.wait_for_x_server():
            self.log("X server not available", 'error')
            return False
        
        browser_cmd = self.find_browser()
        if not browser_cmd:
            self.log("No browser found", 'error')
            return False
        
        # Check connectivity
        if not self.check_url_connectivity(url):
            self.log("URL not reachable, will retry", 'warning')
            # Continue anyway - browser might handle it better
        
        # Show loading page first
        loading_url = self.create_loading_page(url)
        
        # Build browser command
        browser_type = self.config.get("browser_type", "chromium")
        
        if "kiosk_flags" in self.config and self.config["kiosk_flags"]:
            kiosk_flags = self.config["kiosk_flags"]
        else:
            # Default flags
            if browser_type == "firefox":
                kiosk_flags = ["-kiosk", "--new-instance"]
            else:
                kiosk_flags = [
                    "--kiosk",
                    "--noerrdialogs",
                    "--disable-infobars",
                    "--disable-session-crashed-bubble",
                    "--no-sandbox",
                    "--user-data-dir=/tmp/chromium-piview"
                ]
                
                # Add GPU disabling if not using hardware accel
                if not self.config.get("enable_hardware_acceleration", False):
                    kiosk_flags.extend([
                        "--disable-gpu",
                        "--disable-software-rasterizer"
                    ])
                
                # SSL handling
                if self.config.get("ignore_ssl_errors", True):
                    kiosk_flags.extend([
                        "--ignore-certificate-errors",
                        "--allow-insecure-localhost"
                    ])
        
        cmd = [browser_cmd] + kiosk_flags + [loading_url]
        
        try:
            env = os.environ.copy()
            self.browser_process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env
            )
            
            time.sleep(2)
            if self.browser_process.poll() is not None:
                self.log("Browser died immediately", 'error')
                return False
            
            self.browser_launch_time = time.time()
            self.log(f"Browser started: {browser_cmd}")
            return True
            
        except Exception as e:
            self.log(f"Browser launch failed: {e}", 'error')
            return False
    
    def run(self):
        """Main loop"""
        url = self.config.get("url", "http://example.com")
        refresh_interval = self.config.get("refresh_interval", 60)
        safety_level = self.config.get("safety_level", "standard")
        
        self.log("=" * 60)
        self.log(f"Piview - Safety Level: {safety_level.upper()}")
        self.log(f"URL: {url}")
        self.log(f"Refresh: {refresh_interval}s")
        self.log(f"Watchdog: {'ON' if self.config.get('watchdog_enabled') else 'OFF'}")
        self.log(f"Health endpoint: {'ON' if self.config.get('health_endpoint_enabled') else 'OFF'}")
        self.log("=" * 60)
        
        # Wait for network
        for attempt in range(30):
            if self.check_url_connectivity(url):
                break
            if attempt < 29:
                self.log(f"Waiting for network... ({attempt+1}/30)", 'warning')
                time.sleep(10)
        
        # Screen setup
        for _ in range(3):
            self.prevent_screen_blanking()
            time.sleep(1)
        
        # Launch browser
        for attempt in range(5):
            if self.open_url(url):
                break
            if attempt < 4:
                wait = 5 + attempt * 2
                self.log(f"Retry {attempt+1}/5 in {wait}s", 'warning')
                time.sleep(wait)
        
        # Main loop
        last_refresh = time.time()
        
        while self.running:
            time.sleep(1)
            
            # Auto-refresh
            if time.time() - last_refresh >= refresh_interval:
                self.log("Auto-refresh")
                if self.browser_process and self.browser_process.poll() is None:
                    try:
                        if shutil.which("xdotool"):
                            subprocess.run(["xdotool", "key", "F5"],
                                         timeout=2, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
                        else:
                            self.restart_browser()
                    except Exception:
                        self.restart_browser()
                else:
                    self.restart_browser()
                last_refresh = time.time()
        
        self.close_browser()
        self.log("Shutdown complete")

def main():
    try:
        piview = Piview()
        piview.run()
    except Exception as e:
        print(f"FATAL: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
