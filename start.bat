@echo off
title KEVS Siomai Integrated Order Management System
chcp 65001 >nul
cls
echo ======================================================================
echo   🥟 Starting KEVS Siomai Integrated Order Management System...
echo ======================================================================
echo.

if exist "backend\venv\Scripts\python.exe" (
    backend\venv\Scripts\python.exe app.py
) else (
    python app.py
)

pause
