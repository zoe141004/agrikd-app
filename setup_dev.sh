#!/bin/bash
# ============================================================
#  AgriKD — Linux/macOS Development Environment Setup
# ============================================================
#  Prerequisites: Git, Python 3.10+, Flutter SDK, Node.js 18+
#  Run this script from the project root directory.
#
#  Usage:
#    chmod +x setup_dev.sh
#    ./setup_dev.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================================"
echo "  AgriKD Development Setup (Linux/macOS)"
echo "========================================================"
echo ""

# ── 1. Check prerequisites ──────────────────────────────────
echo "[1/7] Checking prerequisites..."

if ! command -v flutter &>/dev/null; then
    echo "  [ERROR] Flutter not found in PATH."
    echo "  Install from: https://docs.flutter.dev/get-started/install"
    exit 1
fi
flutter --version 2>&1 | head -1 | sed 's/^/  /'

if ! command -v python3 &>/dev/null; then
    echo "  [ERROR] Python 3 not found in PATH."
    echo "  Install Python 3.10+ from: https://www.python.org/downloads/"
    exit 1
fi
echo "  $(python3 --version)"

if ! command -v node &>/dev/null; then
    echo "  [ERROR] Node.js not found in PATH."
    echo "  Install from: https://nodejs.org/"
    exit 1
fi
echo "  Node.js $(node --version)"

echo ""
echo "  All prerequisites found."
echo ""

# ── 2. Flutter dependencies ──────────────────────────────────
echo "[2/7] Installing Flutter dependencies..."
cd mobile_app
flutter pub get
cd "$SCRIPT_DIR"
echo "  [OK] Flutter dependencies installed."
echo ""

# ── 3. Python virtual environment ────────────────────────────
echo "[3/7] Setting up Python virtual environment..."
if [ ! -d "venv_mlops" ]; then
    echo "  Creating venv_mlops..."
    python3 -m venv venv_mlops
fi
# shellcheck disable=SC1091
source venv_mlops/bin/activate

echo "  Installing Python dependencies (convert + evaluate)..."
pip install --upgrade pip -q
pip install -r mlops_pipeline/requirements-convert.txt
pip install -r mlops_pipeline/requirements-evaluate.txt

echo "  Installing PyTorch CPU..."
pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cpu

echo ""
echo "  NOTE: Skipping ARM64-only packages (pycuda, tensorrt)."
echo "        These are Jetson-specific and only work on ARM64 Linux."
echo "  [OK] Python environment ready."
echo ""

# ── 4. DVC setup ─────────────────────────────────────────────
echo "[4/7] Setting up DVC..."
pip install dvc dvc-gdrive
echo "  [OK] DVC installed."
echo ""

# ── 5. Admin Dashboard dependencies ─────────────────────────
echo "[5/7] Installing Admin Dashboard dependencies..."
cd admin-dashboard
npm install
cd "$SCRIPT_DIR"
echo "  [OK] Admin Dashboard dependencies installed."
echo ""

# ── 6. Environment configuration ────────────────────────────
echo "[6/7] Setting up environment variables..."
if [ ! -f ".env" ]; then
    if [ -f ".env.development" ]; then
        echo "  Copying .env.development → .env (public keys for dev)..."
        cp .env.development .env
    elif [ -f ".env.example" ]; then
        echo "  Copying .env.example → .env..."
        cp .env.example .env
        echo ""
        echo "  ************************************************************"
        echo "  *  IMPORTANT: Edit .env with your actual credentials.      *"
        echo "  *  Then re-run this script or run: python3 sync_env.py     *"
        echo "  ************************************************************"
        echo ""
    fi
fi

echo "  Syncing environment to sub-projects..."
python3 sync_env.py
echo ""

# ── 7. Verify setup ─────────────────────────────────────────
echo "[7/7] Verifying setup..."
cd mobile_app
flutter analyze || echo "  [WARN] flutter analyze found issues (see above)."
cd "$SCRIPT_DIR"
echo ""

deactivate 2>/dev/null || true

echo "========================================================"
echo "  Setup Complete!"
echo "========================================================"
echo ""
echo "  Next steps:"
echo "    1. Edit .env with your Supabase + Google credentials (if needed)"
echo "    2. Run: python3 sync_env.py"
echo "    3. Run: cd mobile_app && flutter run"
echo "    4. Admin: cd admin-dashboard && npm run dev"
echo "    5. MLOps: source venv_mlops/bin/activate && cd mlops_pipeline/scripts && python run_pipeline.py --config ../configs/tomato.json"
echo ""
echo "  For Jetson deployment, use jetson/setup_jetson.sh on the Jetson device."
echo "========================================================"
