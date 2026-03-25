#!/bin/bash
# AgriKD Jetson Setup Script
# Run this on your Jetson device to deploy the edge inference service.
#
# Prerequisites:
#   - JetPack SDK installed (includes TensorRT, CUDA, cuDNN)
#   - ONNX model files available
#
# Usage:
#   chmod +x setup_jetson.sh
#   sudo ./setup_jetson.sh

set -e

INSTALL_DIR="/opt/agrikd"
SERVICE_USER="agrikd"

echo "========================================"
echo "  AgriKD Jetson Edge Deployment Setup"
echo "========================================"

# 1. Create user
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "[1/7] Creating service user: $SERVICE_USER"
    useradd -m -s /bin/bash "$SERVICE_USER"
else
    echo "[1/7] User $SERVICE_USER already exists"
fi

# 2. Create directories
echo "[2/7] Creating directories..."
mkdir -p "$INSTALL_DIR"/{app,config,models,data,logs}

# 3. Copy files
echo "[3/7] Copying application files..."
cp -r app/* "$INSTALL_DIR/app/"
cp -r config/* "$INSTALL_DIR/config/"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# 4. Install Python dependencies
echo "[4/7] Installing Python dependencies..."
pip3 install --no-cache-dir numpy opencv-python-headless requests flask

# 5. Convert ONNX models to TensorRT
echo "[5/7] Converting models to TensorRT..."
for model_dir in ../../models/*/; do
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
done

# 6. Install systemd service
echo "[6/7] Installing systemd service..."
cp agrikd.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable agrikd.service

# 7. Update config with Supabase credentials (optional)
echo "[7/7] Configuration..."
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
echo "Commands:"
echo "  sudo systemctl start agrikd      # Start service"
echo "  sudo systemctl status agrikd     # Check status"
echo "  sudo journalctl -u agrikd -f     # View logs"
echo "  curl http://localhost:8080/health # Health check"
echo ""
echo "To run inference via API:"
echo '  curl -X POST http://localhost:8080/predict \'
echo '    -F "image=@leaf_photo.jpg" \'
echo '    -F "leaf_type=tomato"'
echo ""
