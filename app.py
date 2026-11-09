#!/usr/bin/env python
"""
======================================================================
  🥟 KEVS SIOMAI — INTEGRATED ORDER MANAGEMENT SYSTEM
  One-Click Launcher (Port 5000)
======================================================================
Usage:
  python app.py
======================================================================
"""

import os
import sys
import time
import subprocess
import webbrowser
import threading

ROOT_DIR    = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.join(ROOT_DIR, 'backend')
FRONTEND_DIR= os.path.join(ROOT_DIR, 'frontend')

# Reconfigure console for Windows Unicode / emoji support
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

# Prefer backend venv python if available
VENV_PYTHON = os.path.join(BACKEND_DIR, 'venv', 'Scripts', 'python.exe')
if not os.path.exists(VENV_PYTHON):
    VENV_PYTHON = os.path.join(BACKEND_DIR, 'venv', 'bin', 'python')
PYTHON_EXE = VENV_PYTHON if os.path.exists(VENV_PYTHON) else sys.executable


def print_banner():
    print('\n' + '=' * 68)
    print('       KEVS SIOMAI — INTEGRATED ORDER MANAGEMENT SYSTEM')
    print('=' * 68)
    print('  Admin Dashboard:    http://localhost:5000')
    print('  Customer Mobile App: http://localhost:5000/mobile')
    print('  Login:              admin  /  kevs2024')
    print('-' * 68)


def open_browser_once(url, delay=1.8):
    """Open browser exactly once after server starts."""
    def _go():
        time.sleep(delay)
        print(f'\n🌐 Opening {url} in your default browser...')
        try:
            webbrowser.open(url)
        except Exception:
            pass
    threading.Thread(target=_go, daemon=True).start()


def get_local_ip():
    """Detect the active local Wi-Fi / LAN IP address."""
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return 'localhost'


def main():
    local_ip = get_local_ip()
    url = f'http://{local_ip}:5000/'
    mobile_url = f'http://{local_ip}:5000/mobile'
    print_banner()
    print(f'  ➜ Admin Dashboard:  http://localhost:5000')
    print(f'  ➜ Customer Mobile:  {mobile_url}')
    print(f'  ➜ Network / ESP32:  {url}\n')

    # Prevent backend from opening a second browser window
    env = os.environ.copy()
    env['KEVS_LAUNCHED'] = '1'
    env['PYTHONUNBUFFERED'] = '1'

    # Open single browser window
    open_browser_once(url)

    cmd = [PYTHON_EXE, '-u', 'app.py']
    try:
        subprocess.run(cmd, cwd=BACKEND_DIR, env=env)
    except KeyboardInterrupt:
        print('\n System stopped.')


if __name__ == '__main__':
    main()
