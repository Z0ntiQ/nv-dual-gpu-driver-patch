@echo off
rem ============================================================
rem  NVIDIA dual-GPU driver patch (Tesla + GeForce on one driver)
rem  Double-click. Self-elevates. Reads parameters, then patches,
rem  signs, enables test signing and reboots. The install phase
rem  finishes automatically after the reboot.
rem ============================================================
setlocal
set "TARGET_HWID=PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043"
set "TARGET_NAME=NVIDIA GeForce RTX 2060"
set "DONOR_HWID=DEV_1EB8"
set "ANCHOR_HWID=DEV_1DB6"
set "WORKDIR=E:\AI\nv_dualgpu"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo.
echo  Target GPU : %TARGET_NAME%
echo  HWID       : %TARGET_HWID%
echo  Donor      : %DONOR_HWID%   Anchor: %ANCHOR_HWID%
echo  Work dir   : %WORKDIR%
echo.
echo  The machine WILL REBOOT in a few seconds after the patch.
echo.
choice /c YN /m "Continue"
if errorlevel 2 exit /b

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch-nv-dual-gpu.ps1" ^
  -Phase Prep -TargetHwid "%TARGET_HWID%" -TargetName "%TARGET_NAME%" ^
  -DonorHwid "%DONOR_HWID%" -AnchorHwid "%ANCHOR_HWID%" -WorkDir "%WORKDIR%"

echo.
pause
