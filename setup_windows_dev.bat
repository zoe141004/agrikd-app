@echo off
REM ============================================================
REM  AgriKD Windows Development Environment Setup
REM ============================================================
REM  Prerequisites: Git, Python 3.10+, Flutter SDK, Node.js 18+
REM  Run this script from the project root directory.
REM ============================================================

setlocal enabledelayedexpansion

echo ========================================================
echo   AgriKD Windows Development Setup
echo ========================================================
echo.

REM ── 1. Check prerequisites ────────────────────────────────
echo [1/7] Checking prerequisites...
echo.

where flutter >nul 2>&1
if errorlevel 1 (
    echo   [ERROR] Flutter not found in PATH.
    echo   Install from: https://docs.flutter.dev/get-started/install/windows
    exit /b 1
)
for /f "tokens=*" %%i in ('flutter --version 2^>^&1 ^| findstr "Flutter"') do echo   %%i

where python >nul 2>&1
if errorlevel 1 (
    echo   [ERROR] Python not found in PATH.
    echo   Install Python 3.10+ from: https://www.python.org/downloads/
    exit /b 1
)
for /f "tokens=*" %%i in ('python --version 2^>^&1') do echo   %%i

where node >nul 2>&1
if errorlevel 1 (
    echo   [ERROR] Node.js not found in PATH.
    echo   Install from: https://nodejs.org/
    exit /b 1
)
for /f "tokens=*" %%i in ('node --version 2^>^&1') do echo   Node.js %%i

echo.
echo   All prerequisites found.
echo.

REM ── 2. Flutter dependencies ────────────────────────────────
echo [2/7] Installing Flutter dependencies...
cd mobile_app
call flutter pub get
if errorlevel 1 (
    echo   [ERROR] flutter pub get failed.
    exit /b 1
)
cd ..
echo   [OK] Flutter dependencies installed.
echo.

REM ── 3. Python virtual environment ─────────────────────────
echo [3/7] Setting up Python virtual environment...
if not exist "venv_mlops" (
    echo   Creating venv_mlops...
    python -m venv venv_mlops
)
call venv_mlops\Scripts\activate.bat

echo   Installing Python dependencies (convert + evaluate)...
pip install --upgrade pip >nul 2>&1
pip install -r mlops_pipeline\requirements-convert.txt
if errorlevel 1 (
    echo   [WARN] Some convert dependencies failed to install.
)
pip install -r mlops_pipeline\requirements-evaluate.txt
if errorlevel 1 (
    echo   [WARN] Some evaluate dependencies failed to install.
)

echo   Installing PyTorch CPU (Windows x64)...
pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cpu
if errorlevel 1 (
    echo   [WARN] PyTorch installation failed. MLOps pipeline may not work.
)

echo.
echo   NOTE: Skipping ARM64-only packages (pycuda, tensorrt).
echo         These are Jetson-specific and only work on ARM64 Linux.
echo   [OK] Python environment ready.
echo.

REM ── 4. DVC setup ──────────────────────────────────────────
echo [4/7] Setting up DVC...
pip install dvc dvc-gdrive
echo   [OK] DVC installed.
echo.

REM ── 5. Admin Dashboard dependencies ───────────────────────
echo [5/7] Installing Admin Dashboard dependencies...
cd admin-dashboard
call npm install
if errorlevel 1 (
    echo   [WARN] npm install failed. Admin Dashboard may not work.
)
cd ..
echo   [OK] Admin Dashboard dependencies installed.
echo.

REM ── 6. Environment configuration ─────────────────────────
echo [6/7] Setting up environment variables...
if not exist ".env" (
    if exist ".env.development" (
        echo   Copying .env.development -^> .env ^(public keys for dev^)...
        copy .env.development .env >nul
        python sync_env.py
    ) else if exist ".env.example" (
        echo   .env not found. Creating from .env.example...
        copy .env.example .env >nul
        echo.
        echo   ************************************************************
        echo   *  IMPORTANT: Edit .env with your actual credentials.      *
        echo   *  Then re-run this script or run: python sync_env.py      *
        echo   ************************************************************
        echo.
    )
) else (
    echo   .env found. Syncing to sub-projects...
    python sync_env.py
)
echo.

REM ── 7. Verify setup ──────────────────────────────────────
echo [7/7] Verifying setup...
echo.
cd mobile_app
call flutter analyze
cd ..
echo.

echo ========================================================
echo   Setup Complete!
echo ========================================================
echo.
echo   Next steps:
echo     1. Edit .env with your Supabase + Google credentials
echo     2. Run: python sync_env.py
echo     3. Run: cd mobile_app ^& flutter run
echo     4. Admin: cd admin-dashboard ^& npm run dev
echo     5. MLOps: cd mlops_pipeline\scripts ^& python run_pipeline.py --config ..\configs\tomato.json
echo.
echo   For Jetson deployment, use setup_jetson.sh on the Jetson device.
echo ========================================================

endlocal
