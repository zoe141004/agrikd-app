#!/bin/bash
# AgriKD Jetson Setup Script
# Run this on your Jetson device to deploy the edge inference service + GUI.
#
# Prerequisites:
#   - JetPack SDK installed (includes TensorRT, CUDA, cuDNN, Python 3)
#   - Internet connection (to download model from Supabase)
#   - Display connected (for GUI mode, optional)
#
# Usage:
#   chmod +x setup_jetson.sh
#   sudo ./setup_jetson.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/agrikd"
SERVICE_USER="agrikd"
VENV_DIR="$INSTALL_DIR/venv"

echo "========================================"
echo "  AgriKD Jetson Edge Deployment Setup"
echo "========================================"

# 1. Create user
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "[1/12] Creating service user: $SERVICE_USER"
    useradd -m -s /bin/bash "$SERVICE_USER"
else
    echo "[1/12] User $SERVICE_USER already exists"
fi

# 2. Create directories
echo "[2/12] Creating directories..."
mkdir -p "$INSTALL_DIR"/{app,config,models,data/images,logs,scripts}

# 3. Copy files
echo "[3/12] Copying application files..."
cp -r "$SCRIPT_DIR/app/"* "$INSTALL_DIR/app/"
cp -r "$SCRIPT_DIR/config/"* "$INSTALL_DIR/config/"
cp -r "$SCRIPT_DIR/scripts/"* "$INSTALL_DIR/scripts/" 2>/dev/null || true
cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# 4. Install system packages (GUI + camera tools)
echo "[4/12] Installing system packages..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3-venv \
    python3-pyqt5 \
    v4l-utils \
    libgl1-mesa-glx \
    libglib2.0-0
echo "  [OK] System packages installed."

# 5. Create Python venv with system site-packages (for TensorRT/PyCUDA)
# Prefer python3.10; fall back to python3 if it is 3.10.x
JETSON_PYTHON=""
if command -v python3.10 &>/dev/null; then
    JETSON_PYTHON="python3.10"
elif command -v python3 &>/dev/null; then
    PY_VER=$(python3 -c 'import sys; print(sys.version_info.minor)')
    if [ "$PY_VER" = "10" ]; then
        JETSON_PYTHON="python3"
    fi
fi
if [ -z "$JETSON_PYTHON" ]; then
    echo "  [ERROR] Python 3.10 not found. JetPack 5.x ships with Python 3.8."
    echo "  Install: sudo apt install python3.10 python3.10-venv"
    exit 1
fi
echo "  Using $($JETSON_PYTHON --version)"

echo "[5/12] Creating Python 3.10 virtual environment..."
if [ ! -d "$VENV_DIR" ]; then
    $JETSON_PYTHON -m venv --system-site-packages "$VENV_DIR"
    echo "  [OK] venv created at $VENV_DIR"
else
    echo "  [OK] venv already exists at $VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
echo "  Active Python: $(python --version) ($(which python))"

# 6. Install Python dependencies in venv
echo "[6/12] Installing Python dependencies in venv..."
pip install --upgrade pip -q
pip install --no-cache-dir -r "$INSTALL_DIR/requirements.txt"
echo "  [OK] Python dependencies installed."
deactivate

# 7. Download ONNX models from Supabase
echo "[7/12] Downloading ONNX models from Supabase..."
CFG="$INSTALL_DIR/config/config.json"
if [ ! -f "$CFG" ]; then
    echo "  [ERROR] Config not found: $CFG"
    echo "  Copy config.example.json → config/config.json and fill in Supabase credentials first."
    exit 1
fi

# Extract Supabase URL and key from config.json
SUPABASE_URL=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_url',''))")
SUPABASE_KEY=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_key',''))")

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
    echo "  [WARN] Supabase credentials not found in config.json"
    echo "  Skipping ONNX download. You can convert models manually later."
else
    for leaf_type in $(python3 -c "import json; c=json.load(open('$CFG')); print(' '.join(c.get('models',{}).keys()))"); do
        engine_file="$INSTALL_DIR/models/${leaf_type}_student.engine"
        onnx_file="$INSTALL_DIR/models/${leaf_type}_student.onnx"

        if [ -f "$engine_file" ]; then
            echo "  Engine already exists: $leaf_type — skipping download"
            continue
        fi

        echo "  Fetching ONNX URL for $leaf_type..."
        ONNX_RESP=$(curl -sf \
            "${SUPABASE_URL}/rest/v1/rpc/get_latest_onnx_url" \
            -H "apikey: $SUPABASE_KEY" \
            -H "Authorization: Bearer $SUPABASE_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"p_leaf_type\": \"$leaf_type\"}" 2>/dev/null || echo "[]")

        ONNX_URL=$(echo "$ONNX_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['onnx_url'] if r else '')" 2>/dev/null || echo "")

        if [ -z "$ONNX_URL" ]; then
            echo "  [WARN] No ONNX URL found for $leaf_type — skipping"
            continue
        fi

        echo "  Downloading ONNX: $leaf_type..."
        HTTP_CODE=$(curl -sL -w "%{http_code}" -o "$onnx_file" "$ONNX_URL")
        if [ "$HTTP_CODE" = "200" ]; then
            echo "  [OK] Downloaded ONNX for $leaf_type ($(stat --format=%s "$onnx_file") bytes)"
        else
            echo "  [WARN] Download failed (HTTP $HTTP_CODE) for $leaf_type"
            rm -f "$onnx_file"
        fi
    done
fi

# 8. Convert ONNX models to TensorRT
echo "[8/12] Converting models to TensorRT..."
for onnx_file in "$INSTALL_DIR/models"/*_student.onnx; do
    [ -f "$onnx_file" ] || continue
    leaf_type=$(basename "$onnx_file" | sed 's/_student\.onnx$//')
    engine_file="$INSTALL_DIR/models/${leaf_type}_student.engine"

    if [ -f "$engine_file" ]; then
        echo "  Engine already exists: $leaf_type"
        continue
    fi

    echo "  Converting: $leaf_type"
    trtexec \
        --onnx="$onnx_file" \
        --saveEngine="$engine_file" \
        --fp16 \
        --workspace=1024
    chown "$SERVICE_USER:$SERVICE_USER" "$engine_file"

    # Compute SHA-256 and inject into config.json
    HASH=$(sha256sum "$engine_file" | awk '{print $1}')
    python3 -c "
import json, sys
try:
    cfg_path, leaf, sha = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(cfg_path) as f:
        c = json.load(f)
    if 'models' not in c:
        c['models'] = {}
    if leaf not in c['models']:
        c['models'][leaf] = {}
    c['models'][leaf]['sha256_checksum'] = sha
    c['models'][leaf]['engine_path'] = f'models/{leaf}_student.engine'
    with open(cfg_path, 'w') as f:
        json.dump(c, f, indent=4)
except Exception as e:
    print(f'[WARNING] Failed to inject SHA-256 into config: {e}', file=sys.stderr)
" "$CFG" "$leaf_type" "$HASH"
    echo "  SHA-256: ${HASH:0:16}... → config.json"

    # Clean up ONNX after successful conversion
    rm -f "$onnx_file"
    echo "  [OK] Removed ONNX after conversion: $leaf_type"
done

# 9. Install systemd services (headless + GUI)
echo "[9/12] Installing systemd services..."
# Update ExecStart to use venv python
cat > /etc/systemd/system/agrikd.service << SYSTEMD
[Unit]
Description=AgriKD Edge Inference Service
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/app/main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD

cat > /etc/systemd/system/agrikd-gui.service << SYSTEMD
[Unit]
Description=AgriKD GUI Application
After=graphical.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=DISPLAY=:0
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/app/gui_app.py
Restart=on-failure

[Install]
WantedBy=graphical.target
SYSTEMD

systemctl daemon-reload
systemctl enable agrikd.service
echo "  [OK] Headless service enabled. GUI service available (manual start)."

# 10. Camera permissions
echo "[10/12] Setting up camera permissions..."
usermod -aG video "$SERVICE_USER"
echo "  [OK] User $SERVICE_USER added to 'video' group."

# 11. Create desktop shortcut for GUI
echo "[11/12] Creating GUI desktop shortcut..."
cat > /usr/share/applications/agrikd-gui.desktop << DESKTOP
[Desktop Entry]
Name=AgriKD Plant Disease Detection
Comment=Detect plant leaf diseases with AI on NVIDIA Jetson
Exec=$VENV_DIR/bin/python $INSTALL_DIR/app/gui_app.py
Icon=application-x-executable
Terminal=false
Type=Application
Categories=Science;Education;
DESKTOP
chmod 644 /usr/share/applications/agrikd-gui.desktop
echo "  [OK] Desktop shortcut created."

# 12. Zero-Touch Provisioning
echo "[12/12] Zero-Touch Provisioning..."
echo ""
echo "  Get a provisioning token from Admin Dashboard:"
echo "    Dashboard -> Devices -> Provisioning Tokens -> Generate Token"
echo ""
read -rp "  Paste provisioning token (or path to .token file, or 'skip'): " PROVISION_INPUT

if [ "$PROVISION_INPUT" = "skip" ] || [ -z "$PROVISION_INPUT" ]; then
    echo "  Skipped provisioning. Device will run in local-only mode."
    echo "  To provision later:  cd $INSTALL_DIR && $VENV_DIR/bin/python scripts/provision.py <token>"
elif [ -f "$PROVISION_INPUT" ]; then
    cd "$INSTALL_DIR"
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/python" scripts/provision.py --file "$PROVISION_INPUT"
    cd - > /dev/null
else
    cd "$INSTALL_DIR"
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/python" scripts/provision.py "$PROVISION_INPUT"
    cd - > /dev/null
fi

echo ""
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo ""
echo "── Headless Mode (REST API) ──"
echo "  sudo systemctl start agrikd       # Start headless service"
echo "  sudo systemctl status agrikd      # Check status"
echo "  sudo journalctl -u agrikd -f      # View logs"
echo "  curl http://localhost:8080/health  # Health check"
echo ""
echo "── GUI Mode (Desktop Application) ──"
echo "  $VENV_DIR/bin/python $INSTALL_DIR/app/gui_app.py"
echo "  # Or click 'AgriKD Plant Disease Detection' in desktop menu"
echo ""
echo "── API Inference ──"
echo '  curl -X POST http://localhost:8080/predict \'
echo '    -F "image=@leaf_photo.jpg" \'
echo '    -F "leaf_type=tomato"'
echo ""
echo "── Camera Check ──"
echo "  v4l2-ctl --list-devices            # List available cameras"
echo "  ls /dev/video*                      # Check video device nodes"
echo ""
echo "── Provisioning (if skipped) ──"
echo "  cd $INSTALL_DIR && $VENV_DIR/bin/python scripts/provision.py <token>"
echo ""
