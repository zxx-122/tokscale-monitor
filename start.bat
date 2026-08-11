@echo off
rem Tokscale 桌面实时悬浮窗 启动器
rem 直接调用 powershell（隐藏控制台窗口），避免 start 命令在某些环境下挂起
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Start-Widget.ps1"
exit /b 0