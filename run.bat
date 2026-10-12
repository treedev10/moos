@echo off
rem Builds MOOS and starts it in QEMU as a classic BIOS PC. Double-click this file.
python "%~dp0build.py" run
if errorlevel 1 pause
