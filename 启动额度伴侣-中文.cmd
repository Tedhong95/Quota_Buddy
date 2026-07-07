@echo off
cd /d "%~dp0"
start "Quota Buddy" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\QuotaBuddy.ps1" -Language zh-CN

