#!/bin/bash
# ============================================================
#  AgriKD — Jetson Edge Deployment Setup
# ============================================================
#  This script sets up the AgriKD edge inference service on an
#  NVIDIA Jetson device. It is SELF-CONTAINED — you do NOT need
#  to run setup_dev.sh first.
#
#  Two deployment modes (both run directly on host):
#    1. Headless REST API — systemd service with Flask + Waitress
#       (uses system Python + TensorRT + PyCUDA from JetPack)
#    2. GUI Desktop App — systemd service or desktop shortcut
#       (system Python + PyQt5 + camera access)
#
#  NOTE: Docker mode was removed because NVIDIA does not provide an
#  official JetPack 6 base image with TRT 10.x + Python 3.10.
#  Running on host ensures correct TensorRT/PyCUDA/CUDA versions.
#  Security is maintained via systemd sandboxing (ProtectSystem,
#  NoNewPrivileges, PrivateTmp, etc.)
#
#  Steps (13 total):
#     1. Verify platform (ARM64)       8.  Configure Supabase credentials
#     2. Create service user           9.  Download ONNX models
#     3. Create directory structure     10. Convert ONNX → TensorRT
#     4. Copy application files         11. Install systemd services
#     5. Verify Python + TRT + PyCUDA   12. Create desktop shortcut
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
#    - JetPack 6.x+ (includes CUDA, cuDNN, TensorRT, Python 3.10)
#    - Internet connection (to download models from Supabase)
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

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_DIR="/opt/agrikd"
SERVICE_USER="agrikd"

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

# Check Python 3 is available
if ! command -v python3 &>/dev/null; then
    echo "  [ERROR] Python 3 not found."
    echo "  JetPack 6.x should include Python 3.10. Install:"
    echo "    sudo apt-get install -y python3 python3-pip"
    exit 1
fi
PYTHON_VER=$(python3 --version 2>&1)
echo "  [OK] $PYTHON_VER"

# Check TensorRT
set +e
TRT_VER=$(python3 -c "import tensorrt; print(tensorrt.__version__)" 2>/dev/null)
TRT_OK=$?
set -e
if [ $TRT_OK -eq 0 ] && [ -n "$TRT_VER" ]; then
    echo "  [OK] TensorRT $TRT_VER"
else
    echo "  [WARN] TensorRT Python bindings not found."
    echo "  Install: sudo apt-get install -y python3-libnvinfer tensorrt"
fi

# Check PyCUDA
set +e
PYCUDA_VER=$(python3 -c "import pycuda; print(pycuda.VERSION_TEXT)" 2>/dev/null)
PYCUDA_OK=$?
set -e
if [ $PYCUDA_OK -eq 0 ] && [ -n "$PYCUDA_VER" ]; then
    echo "  [OK] PyCUDA $PYCUDA_VER"
else
    echo "  [INFO] PyCUDA not found — will be installed in step 7."
fi

echo "  [OK] Platform: $ARCH"
echo ""

# ── 2. Create service user ──────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    echo "[2/13] Creating service user: $SERVICE_USER"
    useradd -m -s /bin/bash "$SERVICE_USER"
    usermod -aG video,render "$SERVICE_USER"
else
    echo "[2/13] User $SERVICE_USER already exists"
    # Ensure groups (video for cameras/nvhost, render for /dev/dri)
    usermod -aG video,render "$SERVICE_USER" 2>/dev/null || true
fi
echo ""

# ── 3. Create directory structure ────────────────────────────
echo "[3/13] Setting up $INSTALL_DIR ..."

# Check if we should clone full repo (for DVC validation) or just copy files
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
GITHUB_REPO_URL="https://github.com/zoe141004/agrikd-app.git"

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "  [OK] Git repo already exists at $INSTALL_DIR"
    # Pull latest changes
    (cd "$INSTALL_DIR" && git pull --ff-only 2>/dev/null || true)
else
    # Clone full repo for DVC support
    echo "  Cloning full repository for DVC validation support..."
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    git clone --depth 1 "$GITHUB_REPO_URL" "$INSTALL_DIR"
    echo "  [OK] Repository cloned to $INSTALL_DIR"
fi

# Create additional directories not in repo
mkdir -p "$INSTALL_DIR/models" "$INSTALL_DIR/data/images" "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/config/secrets"

echo "  $INSTALL_DIR/"
echo "  ├── app/        # Python application (from jetson/app/)"
echo "  ├── config/     # config.json (runtime settings)"
echo "  ├── dvc/        # DVC tracking files for dataset validation"
echo "  ├── models/     # TensorRT .engine files"
echo "  ├── data/images/ # Active learning image storage"
echo "  ├── logs/       # Rotating log files"
echo "  └── scripts/    # Provisioning + engine builder"
echo ""

# ── 4. Setup application files ──────────────────────────────
echo "[4/13] Setting up application files..."

# The repo is cloned, but app files are in jetson/ subdirectory
# Create symlinks or copy to expected locations
APP_SRC="$INSTALL_DIR/jetson/app"
APP_DST="$INSTALL_DIR/app"
SCRIPTS_SRC="$INSTALL_DIR/jetson/scripts"
SCRIPTS_DST="$INSTALL_DIR/scripts"

# Remove existing and create symlinks to jetson/ subdirectory
rm -rf "$APP_DST" "$SCRIPTS_DST" 2>/dev/null || true
ln -sf "$APP_SRC" "$APP_DST"
ln -sf "$SCRIPTS_SRC" "$SCRIPTS_DST"
echo "  [OK] Symlinked app/ and scripts/ to jetson/ subdirectory"

# Copy requirements.txt
cp "$INSTALL_DIR/jetson/requirements.txt" "$INSTALL_DIR/requirements.txt" 2>/dev/null || true

# DVC is already in the cloned repo - just verify
if [ -d "$INSTALL_DIR/.dvc" ] && [ -d "$INSTALL_DIR/dvc" ]; then
    echo "  [OK] DVC already configured in cloned repo"
else
    echo "  [WARN] DVC not found in repo - on-device validation may not work"
fi

# Config: copy example if config.json doesn't exist yet
CONFIG_DIR="$INSTALL_DIR/config"
mkdir -p "$CONFIG_DIR/secrets"
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    if [ -f "$INSTALL_DIR/jetson/config/config.json" ]; then
        cp "$INSTALL_DIR/jetson/config/config.json" "$CONFIG_DIR/config.json"
    elif [ -f "$INSTALL_DIR/jetson/config/config.example.json" ]; then
        cp "$INSTALL_DIR/jetson/config/config.example.json" "$CONFIG_DIR/config.json"
        echo "  [INFO] Created config.json from config.example.json."
    fi
else
    echo "  [OK] config.json already exists — not overwriting."
fi

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

# Standard permissions: user read-write, others read-only
chmod 755 "$CONFIG_DIR" "$INSTALL_DIR/models"
find "$CONFIG_DIR" "$INSTALL_DIR/models" -type f -exec chmod 644 {} + 2>/dev/null || true
# Data and logs: user read-write
chmod 755 "$INSTALL_DIR/data" "$INSTALL_DIR/logs"
find "$INSTALL_DIR/data" -type d -exec chmod 755 {} + 2>/dev/null || true

echo "  [OK] Files copied. Ownership set to $SERVICE_USER."
echo ""

# ── 5. Verify Python + TensorRT + PyCUDA ─────────────────────
echo "[5/13] Verifying runtime dependencies..."
MISSING_DEPS=""
python3 -c "import tensorrt" 2>/dev/null || MISSING_DEPS="${MISSING_DEPS} tensorrt"
python3 -c "import pycuda" 2>/dev/null || MISSING_DEPS="${MISSING_DEPS} pycuda"
python3 -c "import numpy" 2>/dev/null || MISSING_DEPS="${MISSING_DEPS} numpy"
if [ -n "$MISSING_DEPS" ]; then
    echo "  [WARN] Missing Python packages:$MISSING_DEPS"
    echo "  The headless service may fail to start."
    echo "  Install missing packages before starting the service."
else
    echo "  [OK] All runtime dependencies found (tensorrt, pycuda, numpy)."
fi
echo ""

# ── 6. Install system packages for GUI mode ─────────────────
echo "[6/13] Installing system packages for GUI mode..."
if ! apt-get update -qq; then
    echo "  [ERROR] apt-get update failed — check internet connection"
    exit 1
fi
if ! apt-get install -y --no-install-recommends \
    python3-pyqt5 \
    python3-pip \
    python3-numpy \
    python3-opencv \
    v4l-utils \
    libgl1-mesa-glx \
    libglib2.0-0 \
    curl; then
    echo "  [ERROR] apt-get install failed — check internet and package availability"
    exit 1
fi
echo "  [OK] System packages installed (PyQt5, OpenCV, v4l-utils)."
echo ""

# ── 7. Install Python dependencies (system pip) ─────────────
echo "[7/13] Installing Python dependencies (system pip)..."
# numpy and opencv come from apt (python3-numpy, python3-opencv)
# PyQt5 comes from apt (python3-pyqt5)
# flask + waitress: headless REST API server
# requests: Supabase sync engine
# PyCUDA: CUDA memory management for TRT inference
# numpy pinned to 1.24.x — PyCUDA is compiled against numpy 1.x ABI

# Set CUDA env for PyCUDA compilation (needs cuda.h header)
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export CPATH="$CUDA_HOME/targets/aarch64-linux/include:${CPATH:-}"
export LIBRARY_PATH="$CUDA_HOME/targets/aarch64-linux/lib:${LIBRARY_PATH:-}"

pip3 install --break-system-packages \
    "numpy>=1.24,<2" \
    requests==2.33.0 \
    flask==3.1.3 \
    waitress==3.0.2 \
    pycuda \
    dvc dvc-gs \
    scikit-learn \
    opencv-python-headless==4.8.1.78 \
    2>/dev/null \
|| pip3 install \
    "numpy>=1.24,<2" \
    requests==2.33.0 \
    flask==3.1.3 \
    waitress==3.0.2 \
    pycuda \
    dvc dvc-gs \
    scikit-learn \
    opencv-python-headless==4.8.1.78
echo "  [OK] Python dependencies installed (including DVC for engine validation)."
echo ""

# ── 8. Device Provisioning (MANDATORY) ───────────────────────
echo "[8/13] Device Provisioning..."
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  MANDATORY: Provisioning token required                     │"
echo "  │                                                             │"
echo "  │  Get token from: Admin Dashboard → Devices → Provisioning   │"
echo "  │  Tokens → Generate Token → Copy (the full agrikd:// URL)    │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""

CFG="$INSTALL_DIR/config/config.json"
STATE_FILE="$INSTALL_DIR/data/device_state.json"

# Check if already provisioned
if [ -f "$STATE_FILE" ]; then
    EXISTING_TOKEN=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('device_token',''))" 2>/dev/null || echo "")
    if [ -n "$EXISTING_TOKEN" ]; then
        echo "  [OK] Device already provisioned."
        echo "  Device token: ${EXISTING_TOKEN:0:8}..."
        echo "  To re-provision, use: python3 $INSTALL_DIR/scripts/provision.py --force <TOKEN>"
        echo ""
        # Skip to GCS section
        PROVISION_OK=1
    fi
fi

if [ -z "$PROVISION_OK" ]; then
    # Get token from env or prompt
    PROVISION_TOKEN="${AGRIKD_PROVISION_TOKEN:-}"
    
    if [ -z "$PROVISION_TOKEN" ]; then
        echo ""
        echo "  Enter provisioning token (full token starting with agrikd://):"
        echo "  Example: agrikd://eyJzdWJfaWQiOiJ1cGRrcHZrYmpxc3pzd3VxdW5..."
        echo ""
        read -rp "  Token: " PROVISION_TOKEN
    fi
    
    if [ -z "$PROVISION_TOKEN" ]; then
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────────┐"
        echo "  │  ERROR: Provisioning token is required.                     │"
        echo "  │                                                             │"
        echo "  │  Without provisioning:                                      │"
        echo "  │    - Device won't appear in Dashboard                       │"
        echo "  │    - No cloud sync, no OTA model updates                    │"
        echo "  │    - No remote configuration                                │"
        echo "  │                                                             │"
        echo "  │  Get token: Admin Dashboard → Devices → Provisioning Tokens │"
        echo "  │  Click 'Generate Token' then 'Copy' the full agrikd:// URL  │"
        echo "  └─────────────────────────────────────────────────────────────┘"
        echo ""
        exit 1
    fi
    
    # Run provisioning
    echo "  Running provisioning..."
    set +e
    python3 "$INSTALL_DIR/scripts/provision.py" "$PROVISION_TOKEN"
    PROVISION_RESULT=$?
    set -e
    
    if [ $PROVISION_RESULT -ne 0 ]; then
        echo ""
        echo "  [ERROR] Provisioning failed (exit code: $PROVISION_RESULT)"
        echo "  Common issues:"
        echo "    - Token already used or expired"
        echo "    - Network connectivity"
        echo "    - Invalid token format"
        echo ""
        echo "  Generate a new token: Admin Dashboard → Devices → Provisioning Tokens"
        exit 1
    fi
    
    echo "  [OK] Device provisioned successfully."
fi

# Verify config.json was created by provisioning
if [ ! -f "$CFG" ]; then
    echo "  [ERROR] config.json not found after provisioning."
    exit 1
fi

# Show credential status
echo ""
echo "  ── Config.json credential status ──"
python3 -c "
import json
with open('$CFG') as f:
    c = json.load(f)
url = c.get('sync',{}).get('supabase_url','')
key = c.get('sync',{}).get('supabase_key','')
if url and key:
    print(f'  supabase_url: {url[:50]}...')
    print(f'  supabase_key: {key[:25]}...')
    print('  Status: CONFIGURED')
else:
    print('  [ERROR] Credentials missing after provisioning!')
    exit(1)
"
echo ""

# ── 8b. GCS credentials for DVC dataset validation ──────────
echo "  ── GCS credentials (for on-device engine validation) ──"
GCS_SECRET_DIR="$INSTALL_DIR/config/secrets"
GCS_KEY_PATH="$GCS_SECRET_DIR/gcs-readonly.json"
mkdir -p "$GCS_SECRET_DIR"

if [ -n "$AGRIKD_GCS_KEY_DATA" ]; then
    echo "$AGRIKD_GCS_KEY_DATA" > "$GCS_KEY_PATH"
    echo "  [OK] GCS key saved from AGRIKD_GCS_KEY_DATA env var"
elif [ -n "$AGRIKD_GCS_KEY_FILE" ] && [ -f "$AGRIKD_GCS_KEY_FILE" ]; then
    cp "$AGRIKD_GCS_KEY_FILE" "$GCS_KEY_PATH"
    echo "  [OK] GCS key copied from $AGRIKD_GCS_KEY_FILE"
elif [ -f "$GCS_KEY_PATH" ]; then
    echo "  [OK] GCS key already exists at $GCS_KEY_PATH"
else
    # Try fetching from Supabase system_secrets (if device is already provisioned)
    STATE_FILE="$INSTALL_DIR/data/device_state.json"
    if [ -f "$STATE_FILE" ] && [ -f "$CFG" ]; then
        echo "  Attempting to fetch GCS key from Supabase..."
        python3 -c "
import json, sys, requests

cfg_path, state_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg_path) as f: cfg = json.load(f)
with open(state_path) as f: state = json.load(f)

url = cfg.get('sync', {}).get('supabase_url', '')
key = cfg.get('sync', {}).get('supabase_key', '')
token = state.get('device_token', '')
if not (url and key and token):
    print('  [SKIP] Missing Supabase credentials or device token')
    sys.exit(1)

resp = requests.post(f'{url}/rest/v1/rpc/get_system_secret',
    headers={'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'},
    json={'p_device_token': token, 'p_key': 'gcs_readonly_key'}, timeout=15)

if resp.status_code == 200:
    data = resp.json()
    if data:
        with open(out_path, 'w') as f: f.write(data)
        print('  [OK] GCS key fetched from Supabase system_secrets')
    else:
        print('  [INFO] No GCS key in Supabase yet — admin can upload via Dashboard Settings')
        sys.exit(1)
else:
    print(f'  [WARN] RPC failed with HTTP {resp.status_code}: {resp.text[:200]}')
    sys.exit(1)
" "$CFG" "$STATE_FILE" "$GCS_KEY_PATH" 2>&1 || true
    else
        echo "  [INFO] Device not provisioned yet — GCS key will auto-fetch after provisioning."
        echo "         Run: python3 /opt/agrikd/scripts/provision.py --token <TOKEN>"
    fi
fi

# Set permissions if key exists
if [ -f "$GCS_KEY_PATH" ]; then
    chmod 600 "$GCS_KEY_PATH"
    chown "$SERVICE_USER:$SERVICE_USER" "$GCS_KEY_PATH" 2>/dev/null || true
fi

# Inject gcs config section into config.json
if [ -f "$GCS_KEY_PATH" ] && [ -f "$CFG" ]; then
    python3 -c "
import json, sys
cfg_path = sys.argv[1]
gcs_path = sys.argv[2]
with open(cfg_path) as f:
    c = json.load(f)
c['gcs'] = {'credentials_path': gcs_path}
with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=4)
print('  [OK] GCS config added to config.json')
" "$CFG" "$GCS_KEY_PATH" 2>/dev/null || echo "  [WARN] Could not inject GCS config"
fi
echo ""

# ── 9. Download ONNX models from Supabase ───────────────────
echo "[9/13] Downloading models from Supabase..."
if [ ! -f "$CFG" ]; then
    echo "  [WARN] Config not found: $CFG — skipping model download."
    echo "  Place .onnx files manually at: $INSTALL_DIR/models/"
else
    # Read credentials and device token
    CFG_SUPA_URL=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_url',''))" 2>/dev/null || echo "")
    CFG_SUPA_KEY=$(python3 -c "import json; c=json.load(open('$CFG')); print(c.get('sync',{}).get('supabase_key',''))" 2>/dev/null || echo "")
    DEVICE_TOKEN=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('device_token',''))" 2>/dev/null || echo "")

    if [ -z "$CFG_SUPA_URL" ] || [ -z "$CFG_SUPA_KEY" ]; then
        echo "  [WARN] Supabase credentials not found in config.json."
        echo "  Skipping model download. Place files manually at:"
        echo "    $INSTALL_DIR/models/<leaf_type>_student.engine (or .onnx)"
    else
        # Detect device hardware tag
        HW_MODEL="unknown"
        TRT_VER="unknown"
        if [ -f /proc/device-tree/model ]; then
            HW_MODEL=$(cat /proc/device-tree/model | tr -d '\0' | tr '[:upper:]' '[:lower:]' | sed 's/nvidia //;s/ developer kit//;s/ /-/g')
        fi
        TRT_VER=$(dpkg -l tensorrt 2>/dev/null | awk '/^ii/{print $3}' | cut -d'-' -f1 || echo "unknown")
        DEVICE_TAG="${HW_MODEL}_trt${TRT_VER}"
        echo "  Device tag: $DEVICE_TAG"

        # Helper function to fetch model metadata and update config
        update_model_config() {
            local leaf_type="$1"
            local version="$2"
            local model_path="$3"
            local path_key="$4"  # engine_path or onnx_path
            
            python3 << PYEOF
import json, sys, requests

cfg_path = "$CFG"
leaf_type = "$leaf_type"
version = "$version"
model_path = "$model_path"
path_key = "$path_key"
supa_url = "$CFG_SUPA_URL"
supa_key = "$CFG_SUPA_KEY"

# Fetch model metadata from registry
try:
    resp = requests.get(
        f"{supa_url}/rest/v1/model_registry",
        params={"leaf_type": f"eq.{leaf_type}", "version": f"eq.{version}", 
                "select": "num_classes,class_labels,display_name"},
        headers={"apikey": supa_key, "Authorization": f"Bearer {supa_key}"},
        timeout=10
    )
    meta = resp.json()[0] if resp.status_code == 200 and resp.json() else {}
except:
    meta = {}

# Load and update config
with open(cfg_path) as f:
    c = json.load(f)

if 'models' not in c:
    c['models'] = {}
if leaf_type not in c['models']:
    c['models'][leaf_type] = {}

c['models'][leaf_type][path_key] = model_path
c['models'][leaf_type]['version'] = version

# Add metadata if available
if meta.get('num_classes'):
    c['models'][leaf_type]['num_classes'] = meta['num_classes']
if meta.get('class_labels'):
    c['models'][leaf_type]['class_labels'] = meta['class_labels']
if meta.get('display_name'):
    c['models'][leaf_type]['display_name'] = meta['display_name']

with open(cfg_path, 'w') as f:
    json.dump(c, f, indent=4)

print(f"  Updated config: {leaf_type} v{version} (classes: {meta.get('num_classes', 'N/A')})")
PYEOF
        }

        # Fetch assigned model versions from device config (if provisioned)
        ASSIGNED_MODELS=""
        if [ -n "$DEVICE_TOKEN" ]; then
            echo "  Fetching assigned model versions from device config..."
            DEVICE_CONFIG=$(curl -sf --max-time 15 \
                "${CFG_SUPA_URL}/rest/v1/rpc/device_poll_config" \
                -H "apikey: $CFG_SUPA_KEY" \
                -H "Authorization: Bearer $CFG_SUPA_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"p_device_token\": \"$DEVICE_TOKEN\"}" 2>/dev/null || echo "{}")
            
            ASSIGNED_MODELS=$(echo "$DEVICE_CONFIG" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if data:
        desired = data.get('desired_config', {}) or {}
        model_versions = desired.get('model_versions', {}) or {}
        for lt, ver in model_versions.items():
            print(f'{lt}:{ver}')
except: pass
" 2>/dev/null || echo "")
        fi

        if [ -n "$ASSIGNED_MODELS" ]; then
            echo "  Assigned models: $(echo $ASSIGNED_MODELS | tr '\n' ' ')"
            
            # Download assigned models
            for entry in $ASSIGNED_MODELS; do
                leaf_type=$(echo "$entry" | cut -d: -f1)
                MODEL_VERSION=$(echo "$entry" | cut -d: -f2)
                
                echo "  Querying ONNX for $leaf_type v$MODEL_VERSION..."
                
                # Query exact version from model_registry
                ONNX_RESP=$(curl -sf --max-time 15 \
                    "${CFG_SUPA_URL}/rest/v1/model_registry?leaf_type=eq.${leaf_type}&version=eq.${MODEL_VERSION}&select=onnx_url" \
                    -H "apikey: $CFG_SUPA_KEY" \
                    -H "Authorization: Bearer $CFG_SUPA_KEY" 2>/dev/null || echo "[]")
                
                ONNX_URL=$(echo "$ONNX_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['onnx_url'] if r and r[0].get('onnx_url') else '')" 2>/dev/null || echo "")
                
                if [ -z "$ONNX_URL" ]; then
                    # Fallback to active version
                    echo "  [WARN] No ONNX for $leaf_type v$MODEL_VERSION — trying latest active..."
                    ONNX_RESP=$(curl -sf --max-time 15 \
                        "${CFG_SUPA_URL}/rest/v1/rpc/get_latest_onnx_url" \
                        -H "apikey: $CFG_SUPA_KEY" \
                        -H "Authorization: Bearer $CFG_SUPA_KEY" \
                        -H "Content-Type: application/json" \
                        -d "{\"p_leaf_type\": \"$leaf_type\"}" 2>/dev/null || echo "[]")
                    
                    MODEL_VERSION=$(echo "$ONNX_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['version'] if r else '')" 2>/dev/null || echo "")
                    ONNX_URL=$(echo "$ONNX_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['onnx_url'] if r else '')" 2>/dev/null || echo "")
                    
                    if [ -n "$MODEL_VERSION" ]; then
                        echo "  Fallback to active: $leaf_type v$MODEL_VERSION"
                    fi
                fi
                
                if [ -z "$MODEL_VERSION" ] || [ -z "$ONNX_URL" ]; then
                    echo "  [WARN] No model found for $leaf_type — skipping"
                    continue
                fi
                
                # Download model (same logic as before)
                engine_file="$INSTALL_DIR/models/${leaf_type}_student_v${MODEL_VERSION}.engine"
                onnx_file="$INSTALL_DIR/models/${leaf_type}_student_v${MODEL_VERSION}.onnx"
                
                if [ -f "$engine_file" ]; then
                    echo "  Engine already exists: $leaf_type v$MODEL_VERSION — skipping"
                    continue
                fi
                
                # Try pre-built engine first
                ENGINE_STORAGE_URL="${CFG_SUPA_URL}/storage/v1/object/public/models/engines/${leaf_type}/${MODEL_VERSION}/${DEVICE_TAG}.engine"
                echo "  Trying pre-built engine for $leaf_type v$MODEL_VERSION ($DEVICE_TAG)..."
                HTTP_CODE=$(curl -sL --max-time 120 --connect-timeout 10 -w "%{http_code}" -o "$engine_file" "$ENGINE_STORAGE_URL" 2>/dev/null || echo "000")
                
                if [ "$HTTP_CODE" = "200" ] && [ -s "$engine_file" ]; then
                    ENGINE_SIZE=$(stat --format=%s "$engine_file" 2>/dev/null || echo "0")
                    if [ "$ENGINE_SIZE" -gt 102400 ]; then
                        chown "$SERVICE_USER:$SERVICE_USER" "$engine_file"
                        chmod 644 "$engine_file"
                        echo "  [OK] Downloaded pre-built engine for $leaf_type v$MODEL_VERSION (${ENGINE_SIZE} bytes)"
                        update_model_config "$leaf_type" "$MODEL_VERSION" "models/$(basename $engine_file)" "engine_path"
                        continue
                    fi
                fi
                
                # Download ONNX
                rm -f "$engine_file" 2>/dev/null
                echo "  Downloading ONNX: $leaf_type v$MODEL_VERSION..."
                HTTP_CODE=$(curl -sL --max-time 300 --connect-timeout 10 -w "%{http_code}" -o "$onnx_file" "$ONNX_URL" 2>/dev/null || echo "000")
                
                if [ "$HTTP_CODE" = "200" ] && [ -s "$onnx_file" ]; then
                    ONNX_SIZE=$(stat --format=%s "$onnx_file" 2>/dev/null || echo "0")
                    chown "$SERVICE_USER:$SERVICE_USER" "$onnx_file"
                    chmod 644 "$onnx_file"
                    echo "  [OK] Downloaded ONNX for $leaf_type v$MODEL_VERSION (${ONNX_SIZE} bytes)"
                    update_model_config "$leaf_type" "$MODEL_VERSION" "models/$(basename $onnx_file)" "onnx_path"
                else
                    echo "  [WARN] Failed to download ONNX for $leaf_type (HTTP $HTTP_CODE)"
                fi
            done
        else
            echo "  No assigned models found — downloading latest active models..."
            # Fallback: download active models for all leaf types in model_registry
            LEAF_TYPES=$(curl -sf --max-time 15 \
                "${CFG_SUPA_URL}/rest/v1/model_registry?status=eq.active&select=leaf_type" \
                -H "apikey: $CFG_SUPA_KEY" \
                -H "Authorization: Bearer $CFG_SUPA_KEY" 2>/dev/null | \
                python3 -c "import json,sys; print(' '.join(set(r['leaf_type'] for r in json.load(sys.stdin))))" 2>/dev/null || echo "")
            
            for leaf_type in $LEAF_TYPES; do
                echo "  Querying latest model for $leaf_type..."
                ONNX_RESP=$(curl -sf --max-time 30 --connect-timeout 10 \
                    "${CFG_SUPA_URL}/rest/v1/rpc/get_latest_onnx_url" \
                    -H "apikey: $CFG_SUPA_KEY" \
                    -H "Authorization: Bearer $CFG_SUPA_KEY" \
                    -H "Content-Type: application/json" \
                    -d "{\"p_leaf_type\": \"$leaf_type\"}" 2>/dev/null || echo "[]")

                MODEL_VERSION=$(echo "$ONNX_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['version'] if r else '')" 2>/dev/null || echo "")
                ONNX_URL=$(echo "$ONNX_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r[0]['onnx_url'] if r else '')" 2>/dev/null || echo "")

                if [ -z "$MODEL_VERSION" ]; then
                    echo "  [WARN] No active model found for $leaf_type — skipping"
                    continue
                fi

                engine_file="$INSTALL_DIR/models/${leaf_type}_student_v${MODEL_VERSION}.engine"
                onnx_file="$INSTALL_DIR/models/${leaf_type}_student_v${MODEL_VERSION}.onnx"

                if [ -f "$engine_file" ]; then
                    echo "  Engine already exists: $leaf_type v$MODEL_VERSION — skipping"
                    continue
                fi

                # Try pre-built engine
                ENGINE_STORAGE_URL="${CFG_SUPA_URL}/storage/v1/object/public/models/engines/${leaf_type}/${MODEL_VERSION}/${DEVICE_TAG}.engine"
                echo "  Trying pre-built engine for $leaf_type v$MODEL_VERSION ($DEVICE_TAG)..."
                HTTP_CODE=$(curl -sL --max-time 120 --connect-timeout 10 -w "%{http_code}" -o "$engine_file" "$ENGINE_STORAGE_URL" 2>/dev/null || echo "000")
                if [ "$HTTP_CODE" = "200" ] && [ -s "$engine_file" ]; then
                    ENGINE_SIZE=$(stat --format=%s "$engine_file" 2>/dev/null || echo "0")
                    if [ "$ENGINE_SIZE" -gt 102400 ]; then
                        chown "$SERVICE_USER:$SERVICE_USER" "$engine_file"
                        chmod 644 "$engine_file"
                        echo "  [OK] Downloaded pre-built engine for $leaf_type v$MODEL_VERSION"
                        update_model_config "$leaf_type" "$MODEL_VERSION" "models/$(basename $engine_file)" "engine_path"
                        continue
                    fi
                fi

                # Download ONNX
                rm -f "$engine_file" 2>/dev/null
                echo "  Downloading ONNX: $leaf_type v$MODEL_VERSION..."
                HTTP_CODE=$(curl -sL --max-time 300 --connect-timeout 10 -w "%{http_code}" -o "$onnx_file" "$ONNX_URL" 2>/dev/null || echo "000")
                if [ "$HTTP_CODE" = "200" ] && [ -s "$onnx_file" ]; then
                    ONNX_SIZE=$(stat --format=%s "$onnx_file" 2>/dev/null || echo "0")
                    chown "$SERVICE_USER:$SERVICE_USER" "$onnx_file"
                    chmod 644 "$onnx_file"
                    echo "  [OK] Downloaded ONNX for $leaf_type v$MODEL_VERSION (${ONNX_SIZE} bytes)"
                    update_model_config "$leaf_type" "$MODEL_VERSION" "models/$(basename $onnx_file)" "onnx_path"
                else
                    echo "  [WARN] Failed to download ONNX for $leaf_type (HTTP $HTTP_CODE)"
                fi
            done
        fi
    fi
fi
echo ""
# ── 10. Convert ONNX → TensorRT engines ─────────────────────
echo "[10/13] Converting ONNX models to TensorRT FP16 engines..."

# Locate trtexec — may not be in PATH on JetPack installs
TRTEXEC=""
if command -v trtexec &>/dev/null; then
    TRTEXEC="trtexec"
else
    # Common JetPack locations for trtexec
    for candidate in \
        /usr/src/tensorrt/bin/trtexec \
        /usr/local/cuda/bin/trtexec \
        /usr/lib/tensorrt/bin/trtexec \
        /opt/tensorrt/bin/trtexec; do
        if [ -x "$candidate" ]; then
            TRTEXEC="$candidate"
            echo "  Found trtexec at: $TRTEXEC"
            break
        fi
    done
fi

if [ -z "$TRTEXEC" ]; then
    echo "  [WARN] trtexec not found in PATH or common JetPack locations."
    echo "  Attempting to install TensorRT tools..."
    set +e
    apt-get install -y tensorrt libnvinfer-bin 2>/dev/null
    set -e
    # Re-check after install
    for candidate in \
        /usr/src/tensorrt/bin/trtexec \
        /usr/local/cuda/bin/trtexec; do
        if [ -x "$candidate" ]; then
            TRTEXEC="$candidate"
            echo "  [OK] trtexec installed at: $TRTEXEC"
            break
        fi
    done
    command -v trtexec &>/dev/null && TRTEXEC="trtexec"
fi

if [ -z "$TRTEXEC" ]; then
    echo "  [WARN] trtexec still not available — cannot convert ONNX to TensorRT."
    echo "  Install TensorRT manually:  sudo apt-get install tensorrt"
    echo "  Skipping conversion. Pre-built .engine files can be placed at:"
    echo "    $INSTALL_DIR/models/<leaf_type>_student_v<version>.engine"
else
    for onnx_file in "$INSTALL_DIR/models"/*_student*.onnx; do
        [ -f "$onnx_file" ] || { echo "  No ONNX files to convert."; break; }
        onnx_basename=$(basename "$onnx_file" .onnx)

        # Extract leaf_type and version from filename
        # Versioned: tomato_student_v1.2.0.onnx → leaf=tomato, ver=1.2.0
        # Legacy:    tomato_student.onnx → leaf=tomato, ver=unknown
        if echo "$onnx_basename" | grep -qP '_student_v\d'; then
            leaf_type=$(echo "$onnx_basename" | sed 's/_student_v.*$//')
            onnx_ver=$(echo "$onnx_basename" | sed 's/.*_student_v//')
        else
            leaf_type=$(echo "$onnx_basename" | sed 's/_student$//')
            onnx_ver=""
        fi

        # Engine filename includes version
        if [ -n "$onnx_ver" ]; then
            engine_file="$INSTALL_DIR/models/${leaf_type}_student_v${onnx_ver}.engine"
        else
            engine_file="$INSTALL_DIR/models/${leaf_type}_student.engine"
        fi

        if [ -f "$engine_file" ]; then
            echo "  Engine already exists: $leaf_type v${onnx_ver:-unknown} — skipping"
            continue
        fi

        echo "  Converting: $leaf_type v${onnx_ver:-unknown} (this may take several minutes)..."
        set +e  # trtexec failure should not abort setup
        "$TRTEXEC" \
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
        chmod 644 "$engine_file"

        # Inject SHA-256 + version into config.json
        HASH=$(sha256sum "$engine_file" | awk '{print $1}')
        ENGINE_REL="models/$(basename "$engine_file")"
        python3 -c "
import json, sys
try:
    cfg_path, leaf, sha, eng_path, ver = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    with open(cfg_path) as f:
        c = json.load(f)
    if 'models' not in c:
        c['models'] = {}
    if leaf not in c['models']:
        c['models'][leaf] = {}
    c['models'][leaf]['sha256_checksum'] = sha
    c['models'][leaf]['engine_path'] = eng_path
    if ver:
        c['models'][leaf]['version'] = ver
    with open(cfg_path, 'w') as f:
        json.dump(c, f, indent=4)
except Exception as e:
    print(f'[WARNING] Failed to inject SHA-256 into config: {e}', file=sys.stderr)
" "$CFG" "$leaf_type" "$HASH" "$ENGINE_REL" "$onnx_ver"
        echo "  SHA-256: ${HASH:0:16}... → config.json (version: ${onnx_ver:-unset})"

        # Upload .engine to Supabase Storage for backup
        # NOTE: .engine files are device-specific (GPU arch + TensorRT version).
        #       They only work on the SAME hardware they were built on.
        # Path scheme matches sync_engine._upload_engine_cache():
        #   engines/{leaf_type}/{version}/{device_tag}.engine
        python3 -c "
import json, sys, os, urllib.request, subprocess

cfg_path    = sys.argv[1]
leaf_type   = sys.argv[2]
engine_file = sys.argv[3]
sha256      = sys.argv[4]
version     = sys.argv[5] if len(sys.argv) > 5 else ''

if not version:
    print('  [SKIP] No version info — engine not uploaded.')
    sys.exit(0)

# Read Supabase credentials from config
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
    url = cfg.get('sync', {}).get('supabase_url', '')
    key = cfg.get('sync', {}).get('supabase_key', '')
    if not url or not key:
        print('  [SKIP] No Supabase credentials — engine not uploaded.')
        sys.exit(0)
except Exception as e:
    print(f'  [SKIP] Cannot read config: {e}')
    sys.exit(0)

# Detect device hardware tag (same logic as step 9)
hw_model = 'unknown'
trt_ver  = 'unknown'
try:
    with open('/proc/device-tree/model', 'r') as f:
        hw_model = f.read().strip().rstrip(chr(0))
    hw_model = hw_model.lower().replace('nvidia ', '').replace(' developer kit', '')
    hw_model = hw_model.replace(' ', '-')
except FileNotFoundError:
    pass
try:
    r = subprocess.run(['dpkg', '-l', 'tensorrt'], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith('ii'):
            trt_ver = line.split()[2].split('-')[0]
            break
except Exception:
    pass

device_tag = f'{hw_model}_trt{trt_ver}'

# Unified path: engines/{leaf_type}/{version}/{device_tag}.engine
storage_path = f'engines/{leaf_type}/{version}/{device_tag}.engine'

print(f'  Uploading .engine to storage: {storage_path}')
print(f'    Device: {device_tag}, Version: {version}')

file_size = os.path.getsize(engine_file)
upload_url = f'{url}/storage/v1/object/models/{storage_path}'
headers = {
    'apikey': key,
    'Authorization': f'Bearer {key}',
    'Content-Type': 'application/octet-stream',
    'Content-Length': str(file_size),
    'x-upsert': 'true',
}

with open(engine_file, 'rb') as f:
    req = urllib.request.Request(upload_url, data=f.read(), headers=headers, method='POST')
try:
    with urllib.request.urlopen(req, timeout=300) as resp:
        size_mb = file_size / (1024*1024)
        print(f'  [OK] Uploaded .engine ({size_mb:.1f} MB)')
        print(f'    Path: models/{storage_path}')
        print(f'    SHA-256: {sha256[:16]}...')
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8', errors='replace')[:200]
    print(f'  [WARN] Upload failed ({e.code}): {body}')
except Exception as e:
    print(f'  [WARN] Upload failed: {e}')
" "$CFG" "$leaf_type" "$engine_file" "$HASH" "$onnx_ver"

        # Clean up ONNX after successful conversion
        rm -f "$onnx_file"
        echo "  [OK] Converted + removed ONNX: $leaf_type"
    done
fi
echo ""

# Fix ownership for any files created by root during steps 5-10
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/data" "$INSTALL_DIR/logs" "$INSTALL_DIR/models" 2>/dev/null || true

# ── 11. Install systemd services ────────────────────────────
echo "[11/13] Installing systemd services..."

# Headless service: runs directly on host with system Python + TRT + PyCUDA
# NOTE: Docker mode was removed because NVIDIA does not provide an official
# JetPack 6 Docker image with TRT 10.x + Python 3.10. Running on host
# ensures correct TensorRT/PyCUDA/CUDA versions match the hardware.
cat > /etc/systemd/system/agrikd.service << SYSTEMD
[Unit]
Description=AgriKD Edge Inference Service
After=network-online.target
Wants=network-online.target
# Crash loop protection: max 5 restarts in 300 seconds
StartLimitBurst=5
StartLimitIntervalSec=300

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/app/main.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=agrikd
Environment=PYTHONUNBUFFERED=1

# Resource limits
MemoryMax=1G
CPUQuota=80%

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=$INSTALL_DIR /dev/video0 /dev/video1 /dev/dri

[Install]
WantedBy=multi-user.target
SYSTEMD

# GUI service: runs on host (needs display + camera)
# Auto-detect XAUTHORITY path for X11 access
XAUTH_PATH=""
for xauth_candidate in \
    "/run/user/$(id -u $SERVICE_USER)/gdm/Xauthority" \
    "/home/$SERVICE_USER/.Xauthority" \
    "/run/user/1000/gdm/Xauthority"; do
    if [ -f "$xauth_candidate" ]; then
        XAUTH_PATH="$xauth_candidate"
        break
    fi
done
# Grant X11 access to service user
if command -v xhost &>/dev/null; then
    DISPLAY=:0 xhost +SI:localuser:$SERVICE_USER 2>/dev/null || true
fi

cat > /etc/systemd/system/agrikd-gui.service << SYSTEMD
[Unit]
Description=AgriKD GUI Application (Host)
After=graphical.target

[Service]
Type=simple
User=$SERVICE_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=${XAUTH_PATH:-/run/user/1000/gdm/Xauthority}
Environment=PYTHONUNBUFFERED=1
Environment=QT_QPA_PLATFORM=xcb
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/app/gui_app.py --config $INSTALL_DIR/config/config.json
Restart=on-failure
RestartSec=5
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR /tmp/.X11-unix /run/user

[Install]
WantedBy=graphical.target
SYSTEMD

systemctl daemon-reload
systemctl enable agrikd.service
echo "  [OK] agrikd.service (headless REST API) — enabled, starts on boot."
echo "  [OK] agrikd-gui.service (Host GUI) — available, manual start."
echo ""

# ── 12. Create desktop shortcut + GUI launcher (GUI) ────────────────────────
echo "[12/13] Creating GUI desktop shortcut..."

# Install run_gui.sh wrapper (always uses /usr/bin/python3)
if [ -f "$REPO_ROOT/jetson/run_gui.sh" ]; then
    cp "$REPO_ROOT/jetson/run_gui.sh" "$INSTALL_DIR/run_gui.sh"
elif [ -f "$INSTALL_DIR/run_gui.sh" ]; then
    :  # already in place
fi
chmod +x "$INSTALL_DIR/run_gui.sh" 2>/dev/null || true
echo "  [OK] run_gui.sh installed (always uses system Python with JetPack TensorRT)."

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

# ── 13. Camera and GPU permissions ─────────────────────────────
echo "[13/13] Verifying camera and GPU permissions..."

# video group: /dev/video* camera access
if getent group video | grep -q "$SERVICE_USER"; then
    echo "  [OK] User $SERVICE_USER is in 'video' group (camera access)."
else
    usermod -aG video "$SERVICE_USER"
    echo "  [OK] Added $SERVICE_USER to 'video' group (camera access)."
fi

# render group: /dev/dri GPU access (required by CUDA/TensorRT)
if getent group render 2>/dev/null | grep -q "$SERVICE_USER"; then
    echo "  [OK] User $SERVICE_USER is in 'render' group (GPU access)."
else
    usermod -aG render "$SERVICE_USER" 2>/dev/null || true
    echo "  [OK] Added $SERVICE_USER to 'render' group (GPU access)."
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
echo ""
echo "── Headless Mode (REST API) ─────────────────────────────"
echo "  sudo systemctl start agrikd        # Start service"
echo "  sudo systemctl status agrikd       # Check status"
echo "  sudo journalctl -u agrikd -f       # View logs"
echo "  curl http://localhost:8080/health   # Health check"
echo ""
echo "── GUI Mode (Host Desktop Application) ──────────────────"
echo "  $INSTALL_DIR/run_gui.sh              # Recommended (auto system Python)"
echo "  /usr/bin/python3 $INSTALL_DIR/app/gui_app.py   # Direct (must use system Python)"
echo "  # Or: sudo systemctl start agrikd-gui"
echo "  # Or: click 'AgriKD Plant Disease Detection' in desktop menu"
echo ""
echo "  ⚠ Do NOT use conda/virtualenv Python — TensorRT is only in system Python."
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
echo "── Service Management ─────────────────────────────────────"
echo "  sudo systemctl stop agrikd         # Stop service"
echo "  sudo systemctl restart agrikd      # Restart service"
echo "  sudo systemctl disable agrikd      # Disable auto-start"
echo "========================================================"
