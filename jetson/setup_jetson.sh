#!/bin/bash
# ============================================================
#  AgriKD — Jetson Edge Deployment Setup
# ============================================================
#  This script sets up the AgriKD edge inference service on an
#  NVIDIA Jetson device. It is SELF-CONTAINED — you do NOT need
#  to run setup_dev.sh first.
#
#  Two deployment modes:
#    1. Headless REST API — runs inside a Docker container
#       (nvidia L4T TensorRT base image, fully isolated)
#    2. GUI Desktop App — runs on host with system Python + PyQt5
#       (needs display + camera access, so runs outside Docker)
#
#  Steps (13 total):
#     1. Verify platform (ARM64)       8.  Configure Supabase credentials
#     2. Create service user           9.  Download ONNX models
#     3. Create directory structure     10. Convert ONNX → TensorRT
#     4. Copy application files         11. Install systemd services
#     5. Build Docker image             12. Create desktop shortcut
#     6. Install system packages        13. Camera permissions
#     7. Install pip packages
#
#  Supabase credentials (step 8) can be provided via:
#    a) Provisioning token from Admin Dashboard (recommended)
#    b) Manual URL + anon key entry
#    c) Environment variables: SUPABASE_URL, SUPABASE_ANON_KEY
#    d) Pre-populated config.json (from sync_env.py on dev machine)
#
#  Prerequisites:
#    - JetPack 5.x+ (includes CUDA, cuDNN, TensorRT, Docker)
#    - nvidia-container-runtime (usually included with JetPack)
#    - Internet connection (to pull Docker image + download models)
#    - Display + camera (GUI mode only)
#
#  Usage:
#    cd <repo-root>/jetson
#    chmod +x setup_jetson.sh
#    sudo ./setup_jetson.sh
#
#    # Or with env vars (for scripted installs / CI):
#    sudo SUPABASE_URL=https://... SUPABASE_ANON_KEY=sb_... ./setup_jetson.sh
#
#  All files are installed to /opt/agrikd/ on the Jetson device.
#  The repo clone is only needed during setup; it is not modified.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="/opt/agrikd"
SERVICE_USER="agrikd"
DOCKER_IMAGE="agrikd-edge"
DOCKER_TAG="latest"

echo "========================================================"
echo "  AgriKD Jetson Edge Deployment Setup"
echo "========================================================"
echo ""
echo "  Repo source:    $SCRIPT_DIR"
echo "  Install target: $INSTALL_DIR"
echo ""

# ── 1. Verify we're on Jetson / ARM64 ───────────────────────
echo "[1/13] Checking platform..."
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "  [WARN] Architecture is $ARCH (expected aarch64 for Jetson)."
    echo "  This script is designed for NVIDIA Jetson devices."
    read -rp "  Continue anyway? (y/N): " CONTINUE
    if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
        echo "  Aborted."
        exit 1
    fi
fi

# Check Docker is available
if ! command -v docker &>/dev/null; then
    echo "  [ERROR] Docker not found."
    echo "  JetPack 5.x+ should include Docker. Install:"
    echo "    sudo apt-get install -y docker.io nvidia-container-runtime"
    exit 1
fi
echo "  [OK] Docker found: $(docker --version | head -1)"

# Check nvidia-container-runtime
if ! docker info 2>/dev/null | grep -q "nvidia"; then
    echo "  [WARN] nvidia-container-runtime may not be configured."
    echo "  GPU acceleration in Docker requires nvidia runtime."
    echo "  Install: sudo apt-get install -y nvidia-container-runtime"
    echo "  Then add to /etc/docker/daemon.json:"
    echo '    { "runtimes": { "nvidia": { "path": "nvidia-container-runtime" } }, "default-runtime": "nvidia" }'
fi

echo "  [OK] Platform: $ARCH"
echo ""

# ── 2. Create service user ──────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "[2/13] Creating service user: $SERVICE_USER"
    useradd -m -s /bin/bash "$SERVICE_USER"
    usermod -aG video "$SERVICE_USER"
    usermod -aG docker "$SERVICE_USER"
else
    echo "[2/13] User $SERVICE_USER already exists"
    # Ensure groups
    usermod -aG video "$SERVICE_USER" 2>/dev/null || true
    usermod -aG docker "$SERVICE_USER" 2>/dev/null || true
fi
echo ""

# ── 3. Create directory structure ────────────────────────────
echo "[3/13] Creating directories at $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"/{app,config,models,data/images,logs,scripts}
echo "  $INSTALL_DIR/"
echo "  ├── app/        # Python application modules"
echo "  ├── config/     # config.json (runtime settings)"
echo "  ├── models/     # TensorRT .engine files"
echo "  ├── data/images/ # Active learning image storage"
echo "  ├── logs/       # Rotating log files"
echo "  └── scripts/    # Provisioning + engine builder"
echo ""

# ── 4. Copy application files from repo ─────────────────────
echo "[4/13] Copying files from $SCRIPT_DIR → $INSTALL_DIR ..."
cp -r "$SCRIPT_DIR/app/"* "$INSTALL_DIR/app/"
cp -r "$SCRIPT_DIR/scripts/"* "$INSTALL_DIR/scripts/" 2>/dev/null || true
cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
cp "$SCRIPT_DIR/Dockerfile" "$INSTALL_DIR/Dockerfile"
cp "$SCRIPT_DIR/.dockerignore" "$INSTALL_DIR/.dockerignore" 2>/dev/null || true
cp "$SCRIPT_DIR/ruff.toml" "$INSTALL_DIR/ruff.toml" 2>/dev/null || true

# Config: copy example if config.json doesn't exist yet
if [ ! -f "$INSTALL_DIR/config/config.json" ]; then
    if [ -f "$SCRIPT_DIR/config/config.json" ]; then
        cp "$SCRIPT_DIR/config/config.json" "$INSTALL_DIR/config/config.json"
    elif [ -f "$SCRIPT_DIR/config/config.example.json" ]; then
        cp "$SCRIPT_DIR/config/config.example.json" "$INSTALL_DIR/config/config.json"
        echo "  [INFO] Created config.json from config.example.json."
        echo "  Edit $INSTALL_DIR/config/config.json to set Supabase credentials."
    fi
else
    echo "  [OK] config.json already exists — not overwriting."
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
echo "  [OK] Files copied. Ownership set to $SERVICE_USER."
echo ""

# ── 5. Build Docker image (for headless REST API) ───────────
echo "[5/13] Building Docker image: $DOCKER_IMAGE:$DOCKER_TAG ..."
echo "  Dockerfile: $INSTALL_DIR/Dockerfile"
echo "  Context:    $INSTALL_DIR/"
echo ""

cd "$INSTALL_DIR"
docker build -t "$DOCKER_IMAGE:$DOCKER_TAG" \
    -f "$INSTALL_DIR/Dockerfile" \
    "$INSTALL_DIR/"
cd "$SCRIPT_DIR"

echo "  [OK] Docker image built: $DOCKER_IMAGE:$DOCKER_TAG"
echo ""

# ── 6. Install system packages for GUI mode ─────────────────
echo "[6/13] Installing system packages for GUI mode..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3-pyqt5 \
    python3-pip \
    python3-numpy \
    python3-opencv \
    v4l-utils \
    libgl1-mesa-glx \
    libglib2.0-0 \
    curl
echo "  [OK] System packages installed (PyQt5, OpenCV, v4l-utils)."
echo ""

# ── 7. Install GUI Python dependencies (system pip) ─────────
echo "[7/13] Installing GUI Python dependencies (system pip)..."
# Only install packages not already available via apt
# numpy and opencv come from apt (python3-numpy, python3-opencv)
# PyQt5 comes from apt (python3-pyqt5)
# flask + waitress are for headless (Docker only), but requests is needed for sync
pip3 install --break-system-packages \
    requests==2.33.0 \
    flask==3.1.3 \
    waitress==3.0.1 \
    2>/dev/null \
|| pip3 install \
    requests==2.33.0 \
    flask==3.1.3 \
    waitress==3.0.1
echo "  [OK] GUI dependencies installed."
echo ""

# ── 8. Configure Supabase credentials ────────────────────────
echo "[8/13] Configuring Supabase credentials..."
echo ""
CFG="$INSTALL_DIR/config/config.json"

# Ensure config.json exists
if [ ! -f "$CFG" ]; then
    echo "  [WARN] config.json not found at $CFG — creating minimal config."
    python3 -c "
import json
cfg = {
    'camera': {'source': 0, 'width': 640, 'height': 480, 'mode': 'manual'},
    'inference': {'input_size': 224, 'imagenet_mean': [0.485, 0.456, 0.406], 'imagenet_std': [0.229, 0.224, 0.225]},
    'models': {},
    'sync': {'supabase_url': '', 'supabase_key': '', 'batch_size': 50, 'interval_seconds': 300},
    'server': {'host': '0.0.0.0', 'port': 8080, 'api_key': ''},
    'database': {'path': 'data/agrikd_jetson.db'},
    'logging': {'level': 'INFO', 'file': 'logs/agrikd.log', 'max_bytes': 104857600, 'backup_count': 5}
}
with open('$CFG', 'w') as f:
    json.dump(cfg, f, indent=4)
"
    chown "$SERVICE_USER:$SERVICE_USER" "$CFG"
fi

# Check if credentials already present in config.json
EXISTING_URL=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_url',''))" 2>/dev/null || echo "")
EXISTING_KEY=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_key',''))" 2>/dev/null || echo "")

if [ -n "$EXISTING_URL" ] && [ -n "$EXISTING_KEY" ]; then
    echo "  [OK] Supabase credentials already configured in config.json."
    echo "  URL: ${EXISTING_URL:0:40}..."
else
    # ── Auto-detect credentials from repo .env / .env.development ──
    # These files contain public keys (safe to read) and are committed in the repo.
    AUTO_URL=""
    AUTO_KEY=""
    for env_file in "$REPO_ROOT/.env" "$REPO_ROOT/.env.development"; do
        if [ -f "$env_file" ] && [ -z "$AUTO_URL" ]; then
            AUTO_URL=$(grep -E '^SUPABASE_URL=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)
            AUTO_KEY=$(grep -E '^SUPABASE_ANON_KEY=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)
        fi
    done

    if [ -n "$AUTO_URL" ] && [ -n "$AUTO_KEY" ]; then
        # Auto-fill from repo .env files
        echo "  [AUTO] Found credentials in repo .env files — injecting into config.json."
        python3 -c "
import json, sys
cfg_path = sys.argv[1]
with open(cfg_path) as f:
    c = json.load(f)
c.setdefault('sync', {})
c['sync']['supabase_url'] = sys.argv[2]
c['sync']['supabase_key'] = sys.argv[3]
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=4)
" "$CFG" "$AUTO_URL" "$AUTO_KEY"
        echo "  URL: ${AUTO_URL:0:40}..."
    elif [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_ANON_KEY:-}" ]; then
        # Accept from environment variables (for CI/CD or scripted installs)
        echo "  [OK] Using credentials from environment variables."
        python3 -c "
import json, sys
cfg_path = sys.argv[1]
with open(cfg_path) as f:
    c = json.load(f)
c.setdefault('sync', {})
c['sync']['supabase_url'] = sys.argv[2]
c['sync']['supabase_key'] = sys.argv[3]
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=4)
" "$CFG" "$SUPABASE_URL" "$SUPABASE_ANON_KEY"
    else
        # Interactive fallback — offer provisioning token or manual entry
        echo "  Supabase credentials are needed to download models and sync data."
        echo "  Could not auto-detect from repo .env files or environment variables."
        echo ""
        echo "  Options:"
        echo "    1) Paste a provisioning token from Admin Dashboard (recommended)"
        echo "       Dashboard → Devices → Provisioning Tokens → Generate Token"
        echo "    2) Enter Supabase URL and anon key manually"
        echo "    3) Skip — configure later (models must be placed manually)"
        echo ""
        read -rp "  Choice [1/2/3]: " CRED_CHOICE

        case "$CRED_CHOICE" in
            1)
                read -rp "  Paste provisioning token (or path to .token file): " PROVISION_INPUT
                if [ -n "$PROVISION_INPUT" ]; then
                    cd "$INSTALL_DIR"
                    set +e  # Provisioning failure should not abort setup
                    if [ -f "$PROVISION_INPUT" ]; then
                        sudo -u "$SERVICE_USER" python3 scripts/provision.py --file "$PROVISION_INPUT"
                    else
                        sudo -u "$SERVICE_USER" python3 scripts/provision.py "$PROVISION_INPUT"
                    fi
                    PROV_EXIT=$?
                    set -e
                    cd "$SCRIPT_DIR"
                    if [ $PROV_EXIT -eq 0 ]; then
                        echo "  [OK] Device provisioned. Credentials injected into config.json."
                    else
                        echo "  [WARN] Provisioning failed (exit $PROV_EXIT). Setup continues."
                        echo "  You can re-provision later: cd $INSTALL_DIR && python3 scripts/provision.py <token>"
                    fi
                else
                    echo "  [SKIP] Empty input — skipping provisioning."
                fi
                ;;
            2)
                read -rp "  Supabase URL: " MANUAL_URL
                read -rp "  Supabase Anon Key: " MANUAL_KEY
                if [ -n "$MANUAL_URL" ] && [ -n "$MANUAL_KEY" ]; then
                    python3 -c "
import json, sys
cfg_path = sys.argv[1]
with open(cfg_path) as f:
    c = json.load(f)
c.setdefault('sync', {})
c['sync']['supabase_url'] = sys.argv[2]
c['sync']['supabase_key'] = sys.argv[3]
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=4)
" "$CFG" "$MANUAL_URL" "$MANUAL_KEY"
                    echo "  [OK] Credentials saved to config.json."
                else
                    echo "  [WARN] Incomplete credentials — skipping."
                fi
                ;;
            *)
                echo "  Skipped credential configuration."
                echo "  To configure later, edit: $CFG"
                echo "  Or run: cd $INSTALL_DIR && python3 scripts/provision.py <token>"
                ;;
        esac
    fi
fi
echo ""

# ── 9. Download ONNX models from Supabase ───────────────────
echo "[9/13] Downloading ONNX models from Supabase..."
if [ ! -f "$CFG" ]; then
    echo "  [WARN] Config not found: $CFG — skipping model download."
    echo "  Place .onnx files manually at: $INSTALL_DIR/models/"
else
    # Re-read credentials (may have been updated by provisioning in step 8)
    CFG_SUPA_URL=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_url',''))" 2>/dev/null || echo "")
    CFG_SUPA_KEY=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_key',''))" 2>/dev/null || echo "")

    if [ -z "$CFG_SUPA_URL" ] || [ -z "$CFG_SUPA_KEY" ]; then
        echo "  [WARN] Supabase credentials not found in config.json."
        echo "  Skipping ONNX download. Place ONNX files manually at:"
        echo "    $INSTALL_DIR/models/<leaf_type>_student.onnx"
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
                "${CFG_SUPA_URL}/rest/v1/rpc/get_latest_onnx_url" \
                -H "apikey: $CFG_SUPA_KEY" \
                -H "Authorization: Bearer $CFG_SUPA_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"p_leaf_type\": \"$leaf_type\"}" 2>/dev/null || echo "[]")

            ONNX_URL=$(echo "$ONNX_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['onnx_url'] if r else '')" 2>/dev/null || echo "")

            if [ -z "$ONNX_URL" ]; then
                echo "  [WARN] No ONNX URL found for $leaf_type — skipping"
                continue
            fi

            echo "  Downloading ONNX: $leaf_type..."
            HTTP_CODE=$(curl -sL -w "%{http_code}" -o "$onnx_file" "$ONNX_URL" 2>/dev/null || echo "000")
            if [ "$HTTP_CODE" = "200" ]; then
                echo "  [OK] Downloaded ONNX for $leaf_type ($(stat --format=%s "$onnx_file" 2>/dev/null || echo '?') bytes)"
            else
                echo "  [WARN] Download failed (HTTP $HTTP_CODE) for $leaf_type"
                rm -f "$onnx_file"
            fi
        done
    fi
fi
echo ""

# ── 10. Convert ONNX → TensorRT engines ─────────────────────
echo "[10/13] Converting ONNX models to TensorRT FP16 engines..."
if ! command -v trtexec &>/dev/null; then
    echo "  [WARN] trtexec not found — cannot convert ONNX to TensorRT."
    echo "  JetPack 5.x+ should include trtexec. Install TensorRT if missing."
    echo "  Skipping conversion. Pre-built .engine files can be placed at:"
    echo "    $INSTALL_DIR/models/<leaf_type>_student.engine"
else
    for onnx_file in "$INSTALL_DIR/models"/*_student.onnx; do
        [ -f "$onnx_file" ] || { echo "  No ONNX files to convert."; break; }
        leaf_type=$(basename "$onnx_file" | sed 's/_student\.onnx$//')
        engine_file="$INSTALL_DIR/models/${leaf_type}_student.engine"

        if [ -f "$engine_file" ]; then
            echo "  Engine already exists: $leaf_type — skipping"
            continue
        fi

        echo "  Converting: $leaf_type (this may take several minutes)..."
        set +e  # trtexec failure should not abort setup
        trtexec \
            --onnx="$onnx_file" \
            --saveEngine="$engine_file" \
            --fp16 \
            --workspace=1024
        TRT_EXIT=$?
        set -e

        if [ $TRT_EXIT -ne 0 ]; then
            echo "  [WARN] trtexec failed for $leaf_type (exit $TRT_EXIT) — skipping"
            rm -f "$engine_file"
            continue
        fi

        chown "$SERVICE_USER:$SERVICE_USER" "$engine_file"

        # Inject SHA-256 into config.json
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
        echo "  [OK] Converted + removed ONNX: $leaf_type"
    done
fi
echo ""

# ── 11. Install systemd services ────────────────────────────
echo "[11/13] Installing systemd services..."

# Headless service: Docker container with GPU access
cat > /etc/systemd/system/agrikd.service << SYSTEMD
[Unit]
Description=AgriKD Edge Inference Service (Docker)
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=-/usr/bin/docker stop agrikd-headless
ExecStartPre=-/usr/bin/docker rm agrikd-headless
ExecStart=/usr/bin/docker run --rm --name agrikd-headless \\
    --runtime=nvidia \\
    --network=host \\
    -v $INSTALL_DIR/config:/app/config:ro \\
    -v $INSTALL_DIR/models:/app/models:ro \\
    -v $INSTALL_DIR/data:/app/data \\
    -v $INSTALL_DIR/logs:/app/logs \\
    $DOCKER_IMAGE:$DOCKER_TAG
ExecStop=/usr/bin/docker stop agrikd-headless
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD

# GUI service: runs on host (needs display + camera)
cat > /etc/systemd/system/agrikd-gui.service << SYSTEMD
[Unit]
Description=AgriKD GUI Application (Host)
After=graphical.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=DISPLAY=:0
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/app/gui_app.py --config $INSTALL_DIR/config/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
SYSTEMD

systemctl daemon-reload
systemctl enable agrikd.service
echo "  [OK] agrikd.service (Docker headless) — enabled, starts on boot."
echo "  [OK] agrikd-gui.service (Host GUI) — available, manual start."
echo ""

# ── 12. Create desktop shortcut (GUI) ────────────────────────
echo "[12/13] Creating GUI desktop shortcut..."
if [ -d "/usr/share/applications" ]; then
    cat > /usr/share/applications/agrikd-gui.desktop << DESKTOP
[Desktop Entry]
Name=AgriKD Plant Disease Detection
Comment=Detect plant leaf diseases with AI on NVIDIA Jetson
Exec=/usr/bin/python3 $INSTALL_DIR/app/gui_app.py --config $INSTALL_DIR/config/config.json
Icon=application-x-executable
Terminal=false
Type=Application
Categories=Science;Education;
DESKTOP
    chmod 644 /usr/share/applications/agrikd-gui.desktop
    echo "  [OK] Desktop shortcut created."
else
    echo "  [SKIP] /usr/share/applications not found (headless system — no desktop)."
fi
echo ""

# ── 13. Camera permissions ────────────────────────────────────
echo "[13/13] Verifying camera permissions..."
if getent group video | grep -q "$SERVICE_USER"; then
    echo "  [OK] User $SERVICE_USER is in 'video' group."
else
    usermod -aG video "$SERVICE_USER"
    echo "  [OK] Added $SERVICE_USER to 'video' group."
fi

# List cameras if v4l2-ctl is available
if command -v v4l2-ctl &>/dev/null; then
    echo "  Connected cameras:"
    v4l2-ctl --list-devices 2>/dev/null | sed 's/^/    /' || echo "    (none detected)"
fi
echo ""

echo ""
echo "========================================================"
echo "  Setup Complete!"
echo "========================================================"
echo ""
echo "  Install location: $INSTALL_DIR"
echo "  Docker image:     $DOCKER_IMAGE:$DOCKER_TAG"
echo ""
echo "── Headless Mode (Docker REST API) ──────────────────────"
echo "  sudo systemctl start agrikd        # Start container"
echo "  sudo systemctl status agrikd       # Check status"
echo "  sudo journalctl -u agrikd -f       # View logs"
echo "  curl http://localhost:8080/health   # Health check"
echo ""
echo "── GUI Mode (Host Desktop Application) ──────────────────"
echo "  python3 $INSTALL_DIR/app/gui_app.py"
echo "  # Or: sudo systemctl start agrikd-gui"
echo "  # Or: click 'AgriKD Plant Disease Detection' in desktop menu"
echo ""
echo "── API Inference ────────────────────────────────────────"
echo '  curl -X POST http://localhost:8080/predict \'
echo '    -F "image=@leaf_photo.jpg" \'
echo '    -F "leaf_type=tomato"'
echo ""
echo "── Camera Check ─────────────────────────────────────────"
echo "  v4l2-ctl --list-devices"
echo "  ls /dev/video*"
echo ""
echo "── Re-provision / Credential Update ─────────────────────"
echo "  cd $INSTALL_DIR"
echo "  python3 scripts/provision.py <token>"
echo ""
echo "── Docker Management ────────────────────────────────────"
echo "  docker images | grep agrikd        # List images"
echo "  docker ps | grep agrikd            # Running containers"
echo "  docker logs agrikd-headless -f     # Container logs"
echo "========================================================"
