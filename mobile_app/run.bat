@echo off
setlocal
cls

echo ======================================================================
echo   BOSS KEVS SIOMAI - Customer Mobile App
echo ======================================================================
echo.

cd /d "%~dp0"

set "BRAVE_PATH="
if exist "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" set "BRAVE_PATH=C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
if not defined BRAVE_PATH if exist "%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe" set "BRAVE_PATH=%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe"
if not defined BRAVE_PATH if exist "C:\Program Files\Google\Chrome\Application\chrome.exe" set "BRAVE_PATH=C:\Program Files\Google\Chrome\Application\chrome.exe"

set "LOCAL_IP="
for /f "delims=" %%a in ('python -c "import socket; print(socket.gethostbyname(socket.gethostname()))" 2^>nul') do (
    set "LOCAL_IP=%%a"
)
if not defined LOCAL_IP (
    for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr IPv4') do (
        if not defined LOCAL_IP set "LOCAL_IP=%%a"
    )
)
if defined LOCAL_IP (
    set "LOCAL_IP=%LOCAL_IP: =%"
) else (
    set "LOCAL_IP=192.168.123.39"
)

echo [OK] Computer IP: %LOCAL_IP%
echo.
echo ======================================================================
echo   HOW TO OPEN ON YOUR PHONE:
echo   1. Connect phone to the same Wi-Fi network.
echo   2. Open Chrome or browser on your phone.
echo   3. Navigate to:  http://%LOCAL_IP%:8080
echo      (Or direct:   http://%LOCAL_IP%:5000/mobile)
echo ======================================================================
echo.

start "" /b cmd /c "timeout /t 3 /nobreak >nul & if defined BRAVE_PATH (\"%BRAVE_PATH%\" http://localhost:8080) else (start http://localhost:8080)"

echo Starting Flutter Web Server on port 8080...
echo.
call flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0 --release

pause
