#!/bin/bash
# AgriKD Jetson Setup Script
# Run this on your Jetson device to deploy the edge inference service + GUI.
#
# Prerequisites:
#   - JetPack SDK installed (includes TensorRT, CUDA, cuDNN)
#   - ONNX model files available
#   - Display connected (for GUI mode)
#
# Usage:
#   chmod +x setup_jetson.sh
#   sudo ./setup_jetson.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/agrikd"
SERVICE_USER="agrikd"

echo "========================================"
echo "  AgriKD Jetson Edge Deployment Setup"
echo "========================================"

# 1. Create user
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "[1/10] Creating service user: $SERVICE_USER"
    useradd -m -s /bin/bash "$SERVICE_USER"
else
    echo "[1/10] User $SERVICE_USER already exists"
fi

# 2. Create directories
echo "[2/10] Creating directories..."
mkdir -p "$INSTALL_DIR"/{app,config,models,data/images,logs}

# 3. Copy files
echo "[3/10] Copying application files..."
cp -r app/* "$INSTALL_DIR/app/"
cp -r config/* "$INSTALL_DIR/config/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# 4. Install Python dependencies (full OpenCV with GUI support)
echo "[4/10] Installing Python dependencies..."
pip3 install --no-cache-dir numpy==1.24.4 opencv-python==4.8.1.78 requests==2.31.0 flask==3.0.3 waitress==3.0.0

# 5. Install GUI dependencies (PyQt5 + camera tools)
echo "[5/10] Installing GUI dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
    python3-pyqt5 \
    v4l-utils \
    libgl1-mesa-glx \
    libglib2.0-0
echo "  [OK] PyQt5, v4l-utils, OpenGL libraries installed."

# 6. Convert ONNX models to TensorRT
echo "[6/10] Converting models to TensorRT..."
for model_dir in "$SCRIPT_DIR/../models"/*/; do
    leaf_type=$(basename "$model_dir")
    onnx_file="$model_dir/${leaf_type}_student.onnx"
    engine_file="$INSTALL_DIR/models/${leaf_type}_student.engine"

    if [ -f "$onnx_file" ] && [ ! -f "$engine_file" ]; then
        echo "  Converting: $leaf_type"
        trtexec \
            --onnx="$onnx_file" \
            --saveEngine="$engine_file" \
            --fp16 \
            --workspace=1024
        chown "$SERVICE_USER:$SERVICE_USER" "$engine_file"
    elif [ -f "$engine_file" ]; then
        echo "  Engine already exists: $leaf_type"
    else
        echo "  ONNX not found: $onnx_file — skipping"
    fi

    # Compute SHA-256 and inject into config.json
    if [ -f "$engine_file" ]; then
        HASH=$(sha256sum "$engine_file" | awk '{print $1}')
        CFG="$INSTALL_DIR/config/config.json"
        if [ -f "$CFG" ]; then
            python3 -c "
import json, sys
try:
    cfg_path = sys.argv[1]
    leaf = sys.argv[2]
    sha = sys.argv[3]
    with open(cfg_path) as f:
        c = json.load(f)
    if 'models' not in c:
        c['models'] = {}
    if leaf not in c['models']:
        c['models'][leaf] = {}
    c['models'][leaf]['sha256_checksum'] = sha
    with open(cfg_path, 'w') as f:
        json.dump(c, f, indent=4)
except Exception as e:
    print(f'[WARNING] Failed to inject SHA-256 into config: {e}', file=sys.stderr)
" "$CFG" "$leaf_type" "$HASH"
            echo "  SHA-256: ${HASH:0:16}... → config.json"
        fi
    fi
done

# 7. Install systemd services (headless + GUI)
echo "[7/10] Installing systemd services..."
cp agrikd.service /etc/systemd/system/
if [ -f agrikd-gui.service ]; then
    cp agrikd-gui.service /etc/systemd/system/
fi
systemctl daemon-reload
systemctl enable agrikd.service
echo "  [OK] Headless service enabled. GUI service available (manual start)."

# 8. Camera permissions
echo "[8/10] Setting up camera permissions..."
usermod -aG video "$SERVICE_USER"
echo "  [OK] User $SERVICE_USER added to 'video' group."
echo "  Verify camera with: v4l2-ctl --list-devices"

# 9. Create desktop shortcut for GUI
echo "[9/10] Creating GUI desktop shortcut..."
cat > /usr/share/applications/agrikd-gui.desktop << 'DESKTOP'
[Desktop Entry]
Name=AgriKD Plant Disease Detection
Comment=Detect plant leaf diseases with AI on NVIDIA Jetson
Exec=/usr/bin/python3 /opt/agrikd/app/gui_app.py
Icon=application-x-executable
Terminal=false
Type=Application
Categories=Science;Education;
DESKTOP
chmod 644 /usr/share/applications/agrikd-gui.desktop
echo "  [OK] Desktop shortcut created."

# 10. Update config with Supabase credentials (optional)
echo "[10/10] Configuration..."
if [ -z "$(grep -o '"supabase_url": ""' $INSTALL_DIR/config/config.json)" ]; then
    echo "  Supabase already configured"
else
    echo "  Supabase not configured. Edit $INSTALL_DIR/config/config.json to add:"
    echo '    "supabase_url": "https://your-project.supabase.co"'
    echo '    "supabase_key": "your-anon-key"'
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
echo "  python3 /opt/agrikd/app/gui_app.py    # Launch GUI manually"
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
