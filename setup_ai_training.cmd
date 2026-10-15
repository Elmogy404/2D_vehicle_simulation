@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if not errorlevel 1 (
    py -3 "%~dp0ai\setup_training.py"
) else (
    python "%~dp0ai\setup_training.py"
)
if errorlevel 1 (
    echo.
    echo Setup failed. Read the error above. Python 3.10 or newer must be installed.
    pause
    exit /b 1
)
echo.
echo Setup completed. Open Godot and select the AI Training tab.
pause
