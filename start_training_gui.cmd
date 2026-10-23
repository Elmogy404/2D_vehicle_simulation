@echo off
setlocal
cd /d "%~dp0"
if not exist ".venv-ai\Scripts\python.exe" (
    echo Run setup_ai_training.cmd first to install the project Python environment.
    pause
    exit /b 1
)
".venv-ai\Scripts\python.exe" "enhanced_training_gui\main_gui.py"
if errorlevel 1 pause
