#!/usr/bin/env python3
"""
Piview - FACTORY-HARDENED Edition
Designed for 24/7 industrial deployment with zero-touch operation
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
    "health_check_interval": 10,
    "max_browser_restarts": 10,
    "ignore_ssl_errors": True,
    "connection_retry_delay": 5,
    "max_connection_retries": 3,
    "watchdog_freeze_threshold": 120,  # seconds
    "watchdog_enabled": True,
    "auto_reboot_enabled": True,
    "auto_reboot_after_failures": 20,  # reboot after this many consecutive failures
    "memory_limit_mb": 1500,  # restart browser if memory exceeds this
    "disk_space_warning_mb": 500,  # warn if disk space below this
    "log_rotation_size_mb": 10,
    "health_endpoint_port": 8888,  # HTTP endpoint for external monitoring
    "kiosk_flags": [
        "--kiosk",
        "--noerrdialogs",
        "--disable-infobars",
        "--disable-session-crashed-bubble",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
        "--disable-gpu-compositing",
        "--disable-accelerated-2d-canvas",
        "--disable-accelerated-video-decode",
        "--disable-accelerated-video-encode",
        "--disable-accelerated-mjpeg-decode",
        "--disable-software-rasterizer",
        "--user-data-dir=/tmp/chromium-piview"
    ]
}

class FactoryPiview:
    def __init__(self):
        self.logger = None
        self.running = True
        self.browser_process = None
        self.browser_restart_count = 0
        self.browser_launch_time = 0
        self.consecutive_failures = 0
        self.total_uptime_start = time.time()
        self.last_successful_load = 0
        self.system_reboots = 0
        
        # Monitoring metrics
        self.metrics = {
            "browser_restarts": 0,
            "network_failures": 0,
            "memory_warnings": 0,
            "disk_warnings": 0,
            "last_health_check": 0,
            "uptime_seconds": 0,
            "last_error": None
        }
        
        self.setup_x_environment()
        self.setup_logging()
        self.config = self.load_config()
        
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        self.prevent_screen_blanking()
        self.start_background_threads()
        
        # Write initial health status
        self.write_health_status()
    
    def setup_x_environment(self):
        """Setup X server environment with fallbacks"""
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
        self.logger = None
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
        """Write health status for external monitoring"""
        try:
            self.metrics["uptime_seconds"] = int(time.time() - self.total_uptime_start)
            self.metrics["last_health_check"] = time.time()
            
            health = {
                "status": "healthy" if self.consecutive_failures < 5 else "degraded",
                "browser_running": self.browser_process is not None and self.browser_process.poll() is None,
                "metrics": self.metrics,
                "timestamp": datetime.now().isoformat()
            }
            
            with open(HEALTH_FILE, 'w') as f:
                json.dump(health, f, indent=2)
        except Exception:
            pass
    
    def check_system_resources(self):
        """Monitor system resources and take action"""
        try:
            # Memory check
            if self.browser_process:
                try:
                    process = psutil.Process(self.browser_process.pid)
                    memory_mb = process.memory_info().rss / (1024 * 1024)
                    
                    limit = self.config.get("memory_limit_mb", 1500)
                    if memory_mb > limit:
                        self.log(f"Browser memory {memory_mb:.0f}MB exceeds limit {limit}MB - restarting", 'warning')
                        self.metrics["memory_warnings"] += 1
                        self.restart_browser()
                        return
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            
            # Disk space check
            disk = shutil.disk_usage("/")
            free_mb = disk.free / (1024 * 1024)
            warning_threshold = self.config.get("disk_space_warning_mb", 500)
            
            if free_mb < warning_threshold:
                self.log(f"Low disk space: {free_mb:.0f}MB free", 'warning')
                self.metrics["disk_warnings"] += 1
                # Clean up old logs
                self.cleanup_old_files()
                
        except Exception as e:
            self.log(f"Resource check error: {e}", 'warning')
    
    def cleanup_old_files(self):
        """Clean up temp files and old logs"""
        try:
            # Clean chromium cache
            cache_dir = Path("/tmp/chromium-piview")
            if cache_dir.exists():
                shutil.rmtree(cache_dir, ignore_errors=True)
                self.log("Cleaned browser cache")
            
            # Keep only last 2 log files
            log_dir = LOG_FILE.parent
            if log_dir.exists():
                old_logs = sorted(log_dir.glob("*.log.old*"))
                for old_log in old_logs[2:]:
                    old_log.unlink()
                    
        except Exception as e:
            self.log(f"Cleanup error: {e}", 'warning')
    
    def watchdog_thread(self):
        """Monitor browser responsiveness - FACTORY HARDENED"""
        last_activity = time.time()
        freeze_threshold = self.config.get("watchdog_freeze_threshold", 120)
        
        while self.running:
            time.sleep(15)
            
            if not self.config.get("watchdog_enabled", True):
                continue
            
            if not self.browser_process or self.browser_process.poll() is not None:
                last_activity = time.time()
                continue
            
            try:
                # Test if browser window exists
                result = subprocess.run(
                    ["xdotool", "search", "--class", "chromium"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    timeout=5
                )
                
                if result.returncode == 0 and result.stdout:
                    last_activity = time.time()
                else:
                    elapsed = time.time() - last_activity
                    if elapsed > freeze_threshold:
                        self.log(f"WATCHDOG: Browser frozen for {elapsed:.0f}s - KILLING", 'error')
                        self.consecutive_failures += 1
                        try:
                            self.browser_process.kill()
                            subprocess.run(["pkill", "-9", "-f", "chromium"], 
                                         timeout=2, check=False,
                                         stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL)
                        except Exception:
                            pass
                        last_activity = time.time()
                        
            except subprocess.TimeoutExpired:
                elapsed = time.time() - last_activity
                if elapsed > freeze_threshold:
                    self.log("WATCHDOG: System unresponsive - force kill", 'error')
                    subprocess.run(["pkill", "-9", "-f", "chromium"], 
                                 timeout=2, check=False,
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
                    last_activity = time.time()
                    self.check_for_emergency_reboot()
            except Exception as e:
                self.log(f"Watchdog error: {e}", 'warning')
    
    def check_for_emergency_reboot(self):
        """Reboot system if failures exceed threshold"""
        if not self.config.get("auto_reboot_enabled", True):
            return
        
        max_failures = self.config.get("auto_reboot_after_failures", 20)
        if self.consecutive_failures >= max_failures:
            self.log(f"EMERGENCY: {self.consecutive_failures} consecutive failures - REBOOTING", 'error')
            self.write_health_status()
            time.sleep(2)
            try:
                subprocess.run(["sudo", "reboot"], timeout=5)
            except Exception:
                # Force reboot if sudo fails
                subprocess.run(["reboot"], timeout=5, check=False)
    
    def screen_keepalive_thread(self):
        """Keep screen alive"""
        while self.running:
            try:
                time.sleep(30)
                self.keep_screen_alive()
                self.prevent_screen_blanking()
            except Exception as e:
                self.log(f"Screen keepalive error: {e}", 'warning')
    
    def health_check_thread(self):
        """Comprehensive health monitoring"""
        while self.running:
            try:
                time.sleep(self.config.get("health_check_interval", 10))
                
                # Check browser process
                if self.browser_process and self.browser_process.poll() is not None:
                    elapsed = time.time() - self.browser_launch_time if self.browser_launch_time > 0 else 999
                    if elapsed >= 15:
                        self.log("Browser died unexpectedly", 'warning')
                        self.consecutive_failures += 1
                        self.restart_browser()
                
                # Check system resources
                self.check_system_resources()
                
                # Update health status
                self.write_health_status()
                
                # Check for emergency reboot
                self.check_for_emergency_reboot()
                
            except Exception as e:
                self.log(f"Health check error: {e}", 'warning')
    
    def health_endpoint_thread(self):
        """HTTP endpoint for external monitoring"""
        try:
            from http.server import HTTPServer, BaseHTTPRequestHandler
            
            class HealthHandler(BaseHTTPRequestHandler):
                def do_GET(self_handler):
                    if self_handler.path == '/health':
                        try:
                            with open(HEALTH_FILE, 'r') as f:
                                health_data = f.read()
                            
                            self_handler.send_response(200)
                            self_handler.send_header('Content-Type', 'application/json')
                            self_handler.end_headers()
                            self_handler.wfile.write(health_data.encode())
                        except Exception:
                            self_handler.send_response(500)
                            self_handler.end_headers()
                    else:
                        self_handler.send_response(404)
                        self_handler.end_headers()
                
                def log_message(self_handler, format, *args):
                    pass  # Suppress HTTP logs
            
            port = self.config.get("health_endpoint_port", 8888)
            server = HTTPServer(('0.0.0.0', port), HealthHandler)
            self.log(f"Health endpoint running on port {port}")
            server.serve_forever()
        except Exception as e:
            self.log(f"Health endpoint error: {e}", 'warning')
    
    def start_background_threads(self):
        """Start all monitoring threads"""
        try:
            threading.Thread(target=self.screen_keepalive_thread, daemon=True).start()
            threading.Thread(target=self.health_check_thread, daemon=True).start()
            
            if self.config.get("watchdog_enabled", True):
                threading.Thread(target=self.watchdog_thread, daemon=True).start()
                self.log("Watchdog enabled")
            
            # Health endpoint for remote monitoring
            threading.Thread(target=self.health_endpoint_thread, daemon=True).start()
                
        except Exception as e:
            self.log(f"Thread start error: {e}", 'warning')
    
    def prevent_screen_blanking(self):
        """Prevent screen blanking"""
        try:
            if os.environ.get('DISPLAY'):
                subprocess.run(
                    ["xset", "s", "off", "-dpms", "s", "noblank"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
        except Exception:
            pass
    
    def keep_screen_alive(self):
        """Send keepalive signals"""
        try:
            if os.environ.get('DISPLAY'):
                subprocess.run(
                    ["xdotool", "mousemove_relative", "--", "1", "0"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1
                )
                time.sleep(0.1)
                subprocess.run(
                    ["xdotool", "mousemove_relative", "--", "-1", "0"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=1
                )
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
            self.log(f"Config load error: {e}", 'warning')
            return DEFAULT_CONFIG.copy()
    
    def signal_handler(self, signum, frame):
        """Graceful shutdown"""
        self.log("Shutting down...")
        self.running = False
        self.close_browser()
        sys.exit(0)
    
    def close_browser(self):
        """Aggressively close browser"""
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
        
        for _ in range(3):
            try:
                subprocess.run(
                    ["pkill", "-9", "-f", "chromium"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                time.sleep(0.5)
            except Exception:
                pass
    
    def create_error_page(self, error_type, url, details=""):
        """Create local error page"""
        error_html = f"""<!DOCTYPE html>
<html>
<head>
    <title>Connection Error</title>
    <meta http-equiv="refresh" content="30">
    <style>
        body {{
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            background: #1a1a1a;
            color: #fff;
        }}
        .error-box {{
            text-align: center;
            padding: 40px;
            background: #2d2d2d;
            border-radius: 10px;
            max-width: 600px;
        }}
        h1 {{ color: #ff6b6b; margin-bottom: 20px; }}
        .url {{ color: #4a9eff; word-break: break-all; }}
        .details {{ color: #ffa500; margin: 20px 0; }}
        .retry {{ margin-top: 20px; color: #888; font-size: 14px; }}
        .timestamp {{ color: #666; font-size: 12px; margin-top: 10px; }}
    </style>
</head>
<body>
    <div class="error-box">
        <h1>⚠️ {error_type}</h1>
        <p><strong>URL:</strong> <span class="url">{url}</span></p>
        <p class="details">{details}</p>
        <p class="retry">Piview will retry automatically...</p>
        <p class="retry">Auto-refresh in 30 seconds</p>
        <p class="timestamp">{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    </div>
</body>
</html>"""
        
        error_file = Path("/tmp/piview_error.html")
        error_file.write_text(error_html)
        return f"file://{error_file}"
    
    def check_url_connectivity(self, url):
        """Check URL with DNS verification"""
        try:
            from urllib.parse import urlparse
            import socket
            
            parsed = urlparse(url)
            hostname = parsed.hostname
            
            if not hostname:
                return False
            
            # DNS check
            try:
                ip = socket.gethostbyname(hostname)
                self.log(f"DNS OK: {hostname} -> {ip}")
            except socket.gaierror:
                self.log(f"DNS FAILED for {hostname}", 'error')
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
        """Wait for X server"""
        for waited in range(max_wait):
            try:
                result = subprocess.run(
                    ["xset", "q"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                if result.returncode == 0:
                    return True
            except Exception:
                pass
            time.sleep(1)
        return False
    
    def find_browser(self):
        """Find browser executable"""
        for browser in ["chromium-browser", "chromium", "google-chrome"]:
            try:
                result = subprocess.run(
                    ["which", browser],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2
                )
                if result.returncode == 0:
                    return browser
            except Exception:
                continue
        return None
    
    def restart_browser(self):
        """Restart with failure tracking"""
        self.metrics["browser_restarts"] += 1
        
        if self.browser_restart_count >= self.config.get("max_browser_restarts", 10):
            self.log("Max restarts reached, waiting...", 'error')
            time.sleep(60)
            self.browser_restart_count = 0
        
        self.close_browser()
        time.sleep(2)
        self.prevent_screen_blanking()
        
        if self.open_url(self.config["url"]):
            self.browser_restart_count = 0
            self.consecutive_failures = 0
            self.last_successful_load = time.time()
        else:
            self.browser_restart_count += 1
            self.consecutive_failures += 1
    
    def open_url(self, url):
        """Open URL with comprehensive error handling"""
        self.close_browser()
        
        if not self.wait_for_x_server():
            return False
        
        browser_cmd = self.find_browser()
        if not browser_cmd:
            self.log("No browser found", 'error')
            return False
        
        # Check connectivity - don't proceed if DNS fails
        if not self.check_url_connectivity(url):
            self.log("URL not reachable - showing error page", 'error')
            url = self.create_error_page(
                "Network Error",
                url,
                "DNS resolution failed or host unreachable"
            )
        
        self.prevent_screen_blanking()
        
        # Minimal, stable flags
        kiosk_flags = [
            "--kiosk",
            "--noerrdialogs",
            "--disable-infobars",
            "--disable-session-crashed-bubble",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--disable-gpu",
            "--disable-gpu-compositing",
            "--disable-accelerated-2d-canvas",
            "--disable-accelerated-video-decode",
            "--disable-accelerated-video-encode",
            "--disable-accelerated-mjpeg-decode",
            "--disable-software-rasterizer",
            "--user-data-dir=/tmp/chromium-piview"
        ]
        
        if not self.config.get("cert_installed", False) and \
           self.config.get("ignore_ssl_errors", True):
            kiosk_flags.extend([
                "--ignore-certificate-errors",
                "--allow-insecure-localhost"
            ])
        
        cmd = [browser_cmd] + kiosk_flags + [url]
        
        try:
            env = os.environ.copy()
            env['DISPLAY'] = os.environ.get('DISPLAY', ':0')
            if 'XAUTHORITY' in os.environ:
                env['XAUTHORITY'] = os.environ['XAUTHORITY']
            
            self.browser_process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env
            )
            
            time.sleep(2)
            if self.browser_process.poll() is not None:
                return False
            
            self.browser_launch_time = time.time()
            time.sleep(5)
            
            if self.browser_process.poll() is None:
                self.log("Browser launched successfully")
                return True
            return False
            
        except Exception as e:
            self.log(f"Launch failed: {e}", 'error')
            return False
    
    def run(self):
        """Main loop - FACTORY HARDENED"""
        url = self.config.get("url", "http://example.com")
        refresh_interval = self.config.get("refresh_interval", 60)
        
        self.log("=" * 60)
        self.log("PIVIEW - FACTORY-HARDENED EDITION")
        self.log(f"URL: {url}")
        self.log(f"Watchdog: {'ENABLED' if self.config.get('watchdog_enabled') else 'DISABLED'}")
        self.log(f"Auto-reboot: {'ENABLED' if self.config.get('auto_reboot_enabled') else 'DISABLED'}")
        self.log(f"Health status: {HEALTH_FILE}")
        self.log("=" * 60)
        
        # Wait for network
        network_attempts = 0
        while not self.check_url_connectivity(url) and self.running:
            network_attempts += 1
            self.log(f"Waiting for network... (attempt {network_attempts})", 'warning')
            time.sleep(10)
            if network_attempts >= 30:  # 5 minutes
                self.log("Network timeout - proceeding anyway", 'error')
                break
        
        # Prevent blanking
        for _ in range(3):
            self.prevent_screen_blanking()
            time.sleep(1)
        
        # Open browser with retries
        for attempt in range(10):
            if self.open_url(url):
                break
            if attempt < 9:
                wait = min(5 + attempt, 15)
                self.log(f"Browser launch failed, retry {attempt+1}/10 in {wait}s", 'warning')
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
                        subprocess.run(["xdotool", "key", "F5"], timeout=2,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    except Exception:
                        self.restart_browser()
                else:
                    self.restart_browser()
                last_refresh = time.time()
        
        self.close_browser()
        self.log("Shutdown complete")

def main():
    try:
        piview = FactoryPiview()
        piview.run()
    except Exception as e:
        print(f"FATAL: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
