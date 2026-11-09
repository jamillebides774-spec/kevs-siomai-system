@echo off
setlocal
cls

echo ======================================================================
echo   BOSS KEVS SIOMAI - Customer Mobile App
echo ======================================================================
echo.

set "LOCAL_IP="
for /f "delims=" %%a in ('python -c "import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('8.8.8.8', 80)); print(s.getsockname()[0]); s.close()" 2^>nul') do (
    set "LOCAL_IP=%%a"
)
if not defined LOCAL_IP (
    for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "IPv4" ^| findstr /v "192.168.114 192.168.242 169.254"') do (
        if not defined LOCAL_IP set "LOCAL_IP=%%a"
    )
)
if defined LOCAL_IP (
    set "LOCAL_IP=%LOCAL_IP: =%"
) else (
    set "LOCAL_IP=192.168.123.52"
)

echo [OK] Detected IP: %LOCAL_IP%
echo.
echo ======================================================================
echo   HOW TO OPEN ON YOUR PHONE:
echo   1. Connect phone to the same Wi-Fi network.
echo   2. Open Chrome or browser on your phone.
echo   3. Recommended (Unified Server): http://%LOCAL_IP%:5000/mobile
echo      (Or standalone dev server):    http://%LOCAL_IP%:8080
echo ======================================================================
echo.

cd /d "%~dp0mobile_app"

if not exist "build\web\index.html" (
    echo Building web release bundle...
    call flutter build web --release --no-tree-shake-icons
    echo.
)

REM Try to open browser on PC
set "BROWSER_PATH="
if exist "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" set "BROWSER_PATH=C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
if not defined BROWSER_PATH if exist "%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe" set "BROWSER_PATH=%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe"
if not defined BROWSER_PATH if exist "C:\Program Files\Google\Chrome\Application\chrome.exe" set "BROWSER_PATH=C:\Program Files\Google\Chrome\Application\chrome.exe"
if not defined BROWSER_PATH if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" set "BROWSER_PATH=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"

if defined BROWSER_PATH (
    start "" /b cmd /c "timeout /t 3 /nobreak >nul & \"%BROWSER_PATH%\" http://localhost:8080"
) else (
    start "" /b cmd /c "timeout /t 3 /nobreak >nul & start http://localhost:8080"
)

echo Starting Flutter Web Server on port 8080...
echo.
call flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0 --release

pause
