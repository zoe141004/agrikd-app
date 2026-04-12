@echo off
REM ============================================================
REM  AgriKD Windows Development Environment Setup
REM ============================================================
REM  Prerequisites: Git, Python 3.10, Flutter SDK, Node.js 18+
REM
REM  IMPORTANT: Create and activate venv BEFORE running this script!
REM
REM  Usage (from project root — the directory containing this file):
REM    python -m venv venv_mlops
REM    venv_mlops\Scripts\activate.bat
REM    setup_windows_dev.bat
REM
REM  The script detects the active venv and installs all Python
REM  packages into it. If no venv is active, it will abort.
REM ============================================================

setlocal enabledelayedexpansion

echo ========================================================
echo   AgriKD Windows Development Setup
echo ========================================================
echo.

REM ── 1. Check venv is active ────────────────────────────────
echo [1/7] Checking Python virtual environment...
echo.

if "%VIRTUAL_ENV%"=="" (
    echo   [ERROR] No Python virtual environment is active.
    echo.
    echo   Please create and activate a venv first:
    echo     cd %~dp0
    echo     python -m venv venv_mlops
    echo     venv_mlops\Scripts\activate.bat
    echo     setup_windows_dev.bat
    exit /b 1
)

echo   [OK] venv active: %VIRTUAL_ENV%

REM Verify Python 3.10
for /f "tokens=*" %%i in ('python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"') do set PY_VER=%%i
if not "%PY_VER%"=="3.10" (
    echo   [ERROR] Python %PY_VER% detected. Python 3.10 is required.
    echo   Recreate venv with Python 3.10:
    echo     py -3.10 -m venv venv_mlops
    exit /b 1
)
for /f "tokens=*" %%i in ('python --version 2^>^&1') do echo   [OK] %%i
echo.

REM ── 2. Check other prerequisites ──────────────────────────
echo [2/7] Checking prerequisites...
echo.

where flutter >nul 2>&1
if errorlevel 1 (
    echo   [ERROR] Flutter not found in PATH.
    echo   Install from: https://docs.flutter.dev/get-started/install/windows
    exit /b 1
)
for /f "tokens=*" %%i in ('flutter --version 2^>^&1 ^| findstr "Flutter"') do echo   %%i

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

REM ── 3. Flutter dependencies ────────────────────────────────
echo [3/7] Installing Flutter dependencies...
echo   Accepting Android SDK licenses (if prompted, type 'y')...
call flutter doctor --android-licenses >nul 2>&1
cd mobile_app
call flutter pub get
if errorlevel 1 (
    echo   [ERROR] flutter pub get failed.
    exit /b 1
)
cd ..
echo   [OK] Flutter dependencies installed.
echo.

REM ── 4. Python packages (into active venv) ──────────────────
echo [4/7] Installing Python packages into venv...
echo   pip location:
where pip
echo.

pip install --upgrade pip >nul 2>&1

echo   Installing MLOps convert + evaluate dependencies...
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

echo   Installing DVC (Data Version Control)...
pip install dvc dvc-gs

echo.
echo   NOTE: ARM64-only packages (pycuda, tensorrt) are Jetson-specific.
echo         They are NOT installed here. See jetson\setup_jetson.sh.
echo   [OK] All Python packages installed into venv.
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
echo   Your venv is still active: %VIRTUAL_ENV%
echo.
echo   Quick start commands (run from project root: %~dp0):
echo.
echo     # Flutter mobile app
echo     cd mobile_app ^& flutter run
echo.
echo     # Admin Dashboard (React)
echo     cd admin-dashboard ^& npm run dev
echo.
echo     # MLOps pipeline (make sure venv is active)
echo     venv_mlops\Scripts\activate.bat
echo     cd mlops_pipeline\scripts
echo     python run_pipeline.py --config ..\configs\tomato.json
echo.
echo   For Jetson deployment (separate setup, no dev setup needed):
echo     See jetson\setup_jetson.sh and docs\guides\jetson_deployment_guide.md
echo ========================================================

endlocal
