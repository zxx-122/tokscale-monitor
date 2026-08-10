@echo off
rem ============================================================
rem  Tokscale 桌面实时悬浮窗
rem  数据引擎: 本目录 node.exe monitor.mjs (直读 opencode.db)
rem  界面:     Start-Widget.ps1 (WPF 置顶悬浮窗)
rem ============================================================
if not exist "%~dp0node_modules" (
  echo [提示] 首次使用请先运行 install.bat 安装依赖
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Start-Widget.ps1"
exit /b 0