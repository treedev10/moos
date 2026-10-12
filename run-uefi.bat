@echo off
rem Builds MOOS and starts it in QEMU as a modern UEFI PC. Double-click this file.
python "%~dp0build.py" uefi
if errorlevel 1 pause
