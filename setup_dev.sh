#!/bin/bash
# ============================================================
#  AgriKD — Linux/macOS Development Environment Setup
# ============================================================
#  Prerequisites: Git, Python 3.10, Flutter SDK, Node.js 18+
#
#  IMPORTANT: Create and activate venv BEFORE running this script!
#
#  Usage (from project root — the directory containing this file):
#    python3.10 -m venv venv_mlops
#    source venv_mlops/bin/activate
#    chmod +x setup_dev.sh
#    ./setup_dev.sh
#
#  The script detects the active venv and installs all Python
#  packages into it. If no venv is active, it will abort.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================================"
echo "  AgriKD Development Setup (Linux/macOS)"
echo "========================================================"
echo ""

# ── 1. Check venv is active ─────────────────────────────────
echo "[1/7] Checking Python virtual environment..."

if [ -z "$VIRTUAL_ENV" ]; then
    echo "  [ERROR] No Python virtual environment is active."
    echo ""
    echo "  Please create and activate a venv first:"
    echo "    cd $(pwd)"
    echo "    python3.10 -m venv venv_mlops"
    echo "    source venv_mlops/bin/activate"
    echo "    ./setup_dev.sh"
    exit 1
fi

echo "  [OK] venv active: $VIRTUAL_ENV"

# Verify Python 3.10
PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if [ "$PY_VERSION" != "3.10" ]; then
    echo "  [WARN] Python $PY_VERSION detected. Python 3.10 is required."
    echo "  Recreate venv: python3.10 -m venv venv_mlops"
    exit 1
fi
echo "  [OK] Python $PY_VERSION ($(python3 --version))"
echo ""

# ── 2. Check other prerequisites ────────────────────────────
echo "[2/7] Checking prerequisites..."

if ! command -v flutter &>/dev/null; then
    echo "  [ERROR] Flutter not found in PATH."
    echo "  Install from: https://docs.flutter.dev/get-started/install"
    exit 1
fi
flutter --version 2>&1 | head -1 | sed 's/^/  /'

if ! command -v node &>/dev/null; then
    echo "  [ERROR] Node.js not found in PATH."
    echo "  Install from: https://nodejs.org/"
    exit 1
fi
echo "  Node.js $(node --version)"

echo ""
echo "  All prerequisites found."
echo ""

# ── 3. Flutter dependencies ──────────────────────────────────
echo "[3/7] Installing Flutter dependencies..."
cd "$SCRIPT_DIR/mobile_app"
flutter pub get
cd "$SCRIPT_DIR"
echo "  [OK] Flutter dependencies installed."
echo ""

# ── 4. Python packages (into active venv) ────────────────────
echo "[4/7] Installing Python packages into venv..."
echo "  pip location: $(which pip)"

pip install --upgrade pip -q

echo "  Installing MLOps convert + evaluate dependencies..."
pip install -r "$SCRIPT_DIR/mlops_pipeline/requirements-convert.txt"
pip install -r "$SCRIPT_DIR/mlops_pipeline/requirements-evaluate.txt"

echo "  Installing PyTorch CPU..."
pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cpu

echo "  Installing DVC (Data Version Control)..."
pip install dvc dvc-gs

echo ""
echo "  NOTE: ARM64-only packages (pycuda, tensorrt) are Jetson-specific."
echo "        They are NOT installed here. See jetson/setup_jetson.sh."
echo "  [OK] All Python packages installed into venv."
echo ""

# ── 5. Admin Dashboard dependencies ─────────────────────────
echo "[5/7] Installing Admin Dashboard dependencies..."
cd "$SCRIPT_DIR/admin-dashboard"
npm install
cd "$SCRIPT_DIR"
echo "  [OK] Admin Dashboard dependencies installed."
echo ""

# ── 6. Environment configuration ────────────────────────────
echo "[6/7] Setting up environment variables..."
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/.env.development" ]; then
        echo "  Copying .env.development → .env (public keys for dev)..."
        cp "$SCRIPT_DIR/.env.development" "$SCRIPT_DIR/.env"
    elif [ -f "$SCRIPT_DIR/.env.example" ]; then
        echo "  Copying .env.example → .env..."
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        echo ""
        echo "  ************************************************************"
        echo "  *  IMPORTANT: Edit .env with your actual credentials.      *"
        echo "  *  Then re-run this script or run: python3 sync_env.py     *"
        echo "  ************************************************************"
        echo ""
    fi
fi

echo "  Syncing environment to sub-projects..."
python3 "$SCRIPT_DIR/sync_env.py"
echo ""

# ── 7. Verify setup ─────────────────────────────────────────
echo "[7/7] Verifying setup..."
cd "$SCRIPT_DIR/mobile_app"
flutter analyze || echo "  [WARN] flutter analyze found issues (see above)."
cd "$SCRIPT_DIR"
echo ""

echo "========================================================"
echo "  Setup Complete!"
echo "========================================================"
echo ""
echo "  Your venv is still active: $VIRTUAL_ENV"
echo ""
echo "  Quick start commands (run from project root: $SCRIPT_DIR):"
echo ""
echo "    # Flutter mobile app"
echo "    cd mobile_app && flutter run"
echo ""
echo "    # Admin Dashboard (React)"
echo "    cd admin-dashboard && npm run dev"
echo ""
echo "    # MLOps pipeline (make sure venv is active)"
echo "    source venv_mlops/bin/activate"
echo "    cd mlops_pipeline/scripts"
echo "    python run_pipeline.py --config ../configs/tomato.json"
echo ""
echo "  For Jetson deployment (separate setup, no dev setup needed):"
echo "    See jetson/setup_jetson.sh and docs/guides/jetson_deployment_guide.md"
echo "========================================================"
