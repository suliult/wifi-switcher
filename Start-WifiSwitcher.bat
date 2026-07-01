@echo off
setlocal
start "Wi-Fi Switcher" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0WifiSwitcher.ps1"
