@echo off
setlocal
chcp 65001 >nul
python --version >nul 2>&1
if not errorlevel 1 (
    python "%~dp0manage_bitstreams.py"
    if errorlevel 1 pause
    exit /b
)
py -3 --version >nul 2>&1
if not errorlevel 1 (
    py -3 "%~dp0manage_bitstreams.py"
    if errorlevel 1 pause
    exit /b
)
echo Python 3 was not found. Please install Python 3 and try again.
pause
