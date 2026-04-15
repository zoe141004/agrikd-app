# Jetson Edge Deployment Guide

> AgriKD -- Plant Leaf Disease Detection on NVIDIA Jetson (Phase 2)

---

## 1. Overview

AgriKD deploys knowledge-distilled MobileNetV2 models to NVIDIA Jetson devices
for real-time plant leaf disease detection at the edge. ONNX models exported by
the MLOps training pipeline are converted on-device to TensorRT FP16 engines,
achieving approximately 1--2 ms per inference on Jetson hardware.

Two deployment modes are provided:

| Mode | Interface | Use Case |
|------|-----------|----------|
| **GUI Desktop Application** | PyQt5 window with live camera preview, file picker, and results panel | Field technicians at an inspection station with a monitor attached to the Jetson |
| **Headless REST API** | Flask server on port 8080 with `/health`, `/predict`, and `/stats` endpoints | Autonomous stations, greenhouse monitoring, or integration with third-party dashboards |

Both modes share the same core modules:

- **TensorRT FP16 inference** -- CUDA-accelerated classification with ImageNet normalization and softmax post-processing.
- **SQLite local storage** (WAL mode) -- every prediction is persisted locally so no data is lost during network outages.
- **Background Supabase sync** -- a daemon thread pushes unsynced predictions to Supabase every 5 minutes (configurable), with automatic retry and batch control.
- **Active Learning** -- every analyzed image is automatically saved in an ImageFolder-compatible directory structure (`data/images/<leaf_type>/`), ready for future model retraining without any additional labeling infrastructure.

Supported models:

| Leaf Type | Classes | Engine File |
|-----------|---------|-------------|
| Tomato | 10 (Bacterial Spot, Early Blight, Late Blight, Leaf Mold, Septoria Leaf Spot, Spider Mites, Target Spot, Yellow Leaf Curl Virus, Mosaic Virus, Healthy) | `tomato_student.engine` (or `tomato_student_v{version}.engine` when managed by sync engine) |
| Burmese Grape Leaf | 5 (Anthracnose, Healthy, Insect Damage, Leaf Spot, Powdery Mildew) | `burmese_grape_leaf_student.engine` (or `burmese_grape_leaf_student_v{version}.engine`) |

---

## 2. Prerequisites

### 2.1 Hardware

- **NVIDIA Jetson** device: Nano, TX2, Xavier NX, AGX Xavier, or Orin series.
- **USB or CSI camera** (any V4L2-compatible device).
- **32 GB+ storage** (microSD, NVMe, or eMMC depending on the Jetson variant).
- **Display and keyboard/mouse** (GUI mode only).

### 2.2 Software

- **JetPack SDK 6.x** installed on the Jetson (includes CUDA, cuDNN, TensorRT, Python 3.10).
- **Ubuntu 22.04** (L4T base image shipped with JetPack 6).
- **Python 3.10** with TensorRT and PyCUDA bindings (pre-installed by JetPack).
- **Git** for cloning the repository.

> **NOTE:** You do NOT need to run `setup_dev.sh` or set up a Python venv on Jetson.
> The Jetson setup is fully self-contained. Both headless and GUI modes run
> directly on the host using system Python with JetPack-provided packages.

### 2.3 ONNX Model Files

ONNX models are produced by the AgriKD MLOps pipeline and stored on
**Supabase Storage** (not in the git repository). The setup script
automatically downloads them and converts to TensorRT engines on-device.

If no Supabase credentials are configured, you can place ONNX files
manually at `$INSTALL_DIR/models/<leaf_type>_student.onnx`
(default: `/opt/agrikd/models/`).

---

## 3. Quick Start

```bash
# Clone the repository
git clone https://github.com/zoe141004/agrikd-app.git
cd agrikd-app/jetson

# Create config.json from the template (config.json is gitignored)
cp config/config.example.json config/config.json
# Edit config/config.json to fill in Supabase credentials if desired

# Run the automated setup (requires root for systemd)
chmod +x setup_jetson.sh
sudo ./setup_jetson.sh
```

After setup completes, choose a deployment mode:

```bash
# Headless REST API (runs as systemd service with system Python)
sudo systemctl start agrikd

# GUI Desktop Application (runs on host with system Python + PyQt5)
/opt/agrikd/run_gui.sh                           # recommended wrapper
# or: /usr/bin/python3 /opt/agrikd/app/gui_app.py  # direct
```

> **Note:** Always use system Python (`/usr/bin/python3`) for the GUI.
> Conda/virtualenv environments do NOT have JetPack TensorRT libraries.

---

## 4. Setup Script Explained

The `setup_jetson.sh` script performs thirteen sequential steps. Each step is
logged to the console with a numbered prefix (`[1/13]` through `[13/13]`).

Run from the repo's `jetson/` directory:

```bash
cd <repo-root>/jetson
sudo ./setup_jetson.sh
```

### Architecture

| Mode | Runtime | Python | Security |
|------|---------|--------|----------|
| **Headless REST API** | Host systemd service | Python 3.10 (system) | systemd sandboxing (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`) |
| **GUI Desktop App** | Host systemd service or desktop shortcut | Python 3.10 (system) | System packages (`python3-pyqt5`, `python3-opencv`) |

> **Why host-native instead of Docker?** NVIDIA does not provide an official
> JetPack 6 Docker base image with TRT 10.x + Python 3.10. Running directly
> on the host ensures correct TensorRT/PyCUDA/CUDA versions match the hardware.
> Security is maintained via systemd hardening directives.

### Step 1 -- Check Platform

Verifies the device is ARM64 (`aarch64`) and that Python 3, TensorRT, and
PyCUDA are available.

### Step 2 -- Create Service User

```bash
useradd -m -s /bin/bash agrikd
usermod -aG video,render agrikd
```

A dedicated `agrikd` user is created with two group memberships:

| Group | Purpose |
|-------|---------|
| `video` | Access to `/dev/video*` (USB/CSI cameras) and `/dev/nvhost-*`, `/dev/nvmap` (NVIDIA GPU devices) |
| `render` | Access to `/dev/dri/renderD*` (GPU hardware acceleration required by CUDA/TensorRT runtime) |

If the user already exists, only group membership is ensured.

### Step 3 -- Create Directories

```bash
mkdir -p /opt/agrikd/{app,config,models,data/images,logs,scripts}
```

| Directory | Purpose |
|-----------|---------|
| `app/` | Python application modules (from `jetson/app/` in repo) |
| `config/` | `config.json` runtime configuration |
| `models/` | TensorRT `.engine` files (built on-device from ONNX) |
| `data/images/` | Active Learning image storage, organized by leaf type |
| `logs/` | Rotating log files for both headless and GUI modes |
| `scripts/` | Provisioning + engine builder utilities |

### Step 4 -- Copy Application Files

All files from the repository's `jetson/app/`, `jetson/scripts/`, and
`jetson/config/` directories are copied into `/opt/agrikd/`. The
`requirements.txt` is also copied for reference. Ownership is set to
the `agrikd` user.

### Step 5 -- Verify Runtime Dependencies

Checks that Python 3 can import `tensorrt`, `pycuda`, and `numpy`. Warns if
any are missing — the headless service will fail to start without them.

### Step 6 -- Install System Packages for GUI

```bash
apt-get install -y --no-install-recommends \
    python3-pyqt5 python3-pip python3-numpy python3-opencv \
    v4l-utils libgl1-mesa-glx libglib2.0-0
```

| Package | Purpose |
|---------|---------|
| `python3-pyqt5` | PyQt5 widget toolkit for the desktop GUI |
| `python3-numpy` | NumPy for image processing (system package) |
| `python3-opencv` | OpenCV with GUI support for camera frames |
| `v4l-utils` | Camera enumeration and diagnostics (`v4l2-ctl`) |
| `libgl1-mesa-glx` | OpenGL runtime for PyQt5 rendering |
| `libglib2.0-0` | GLib library required by OpenCV |

> **Why no venv?** PyQt5 on ARM64 has no pip wheel — it must be installed via
> `apt`. Using system Python ensures PyQt5, TensorRT, and PyCUDA all coexist
> without conflicts.

### Step 7 -- Install Python Dependencies

```bash
export CUDA_HOME=/usr/local/cuda
pip3 install "numpy>=1.24,<2" requests flask waitress pycuda
```

Installs pip packages not available via apt:

| Package | Purpose |
|---------|---------|
| `numpy>=1.24,<2` | Pinned to 1.x — PyCUDA is compiled against numpy 1.x ABI and crashes with numpy 2.x |
| `flask` + `waitress` | Headless REST API server |
| `requests` | Supabase sync engine |
| `pycuda` | CUDA memory management for TensorRT inference (requires `CUDA_HOME` for compilation) |

> **Why pin numpy < 2?** PyCUDA's C extension is compiled against numpy 1.x ABI.
> Installing numpy 2.x causes `AttributeError: _ARRAY_API not found` at runtime.

### Step 8 -- Configure Supabase Credentials

Supabase credentials are needed for model download (step 9) and runtime data sync.
The script checks for credentials in this order:

1. **Already in config.json** — if `sync_env.py` was run on a dev machine and the
   config was copied, credentials are already present.
2. **Environment variables** — pass `SUPABASE_URL` and `SUPABASE_ANON_KEY` to the
   script for CI/CD or scripted installs:
   ```bash
   sudo SUPABASE_URL=https://... SUPABASE_ANON_KEY=sb_... ./setup_jetson.sh
   ```
3. **Interactive prompt** — the script offers three options:
   - **(1) Provisioning token** (recommended) — paste a token from the Admin
     Dashboard (Devices → Provisioning Tokens → Generate Token). This registers
     the device AND injects credentials.
   - **(2) Manual entry** — enter Supabase URL and anon key directly.
   - **(3) Skip** — configure later; models must be placed manually.

### Step 9 -- Download ONNX Models

ONNX models are downloaded from Supabase Storage using the credentials configured
in step 8. If no credentials are configured, this step is skipped and you can
place ONNX files manually:

```bash
# Manual placement
cp tomato_student.onnx /opt/agrikd/models/
cp burmese_grape_leaf_student.onnx /opt/agrikd/models/
```

### Step 10 -- Convert ONNX → TensorRT Engines

```bash
trtexec \
    --onnx=<model>.onnx \
    --saveEngine=<model>.engine \
    --fp16 \
    --workspace=1024
```

Iterates over all `*_student.onnx` files in `/opt/agrikd/models/` and converts
each to a TensorRT FP16 engine. The SHA-256 hash is injected into `config.json`.
ONNX files are deleted after successful conversion.

Engines are hardware-specific and must be built on the target Jetson device.

### Step 11 -- Install systemd Services

Two unit files are installed to `/etc/systemd/system/`:

**`agrikd.service` (Headless — Host Python):**
```ini
ExecStart=/usr/bin/python3 /opt/agrikd/app/main.py
```

Runs directly on the host with system Python 3.10 and JetPack-provided
TensorRT/PyCUDA. Security is enforced via systemd sandboxing directives:
`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, etc.

**`agrikd-gui.service` (GUI — Host Python):**
```ini
ExecStart=/usr/bin/python3 /opt/agrikd/app/gui_app.py \
    --config /opt/agrikd/config/config.json
```

The headless service is enabled by default (starts on boot). The GUI service
is available but not enabled by default.

### Step 12 -- Create Desktop Shortcut

A `.desktop` file is installed to `/usr/share/applications/` so the GUI
application appears in the desktop environment's application menu as
**"AgriKD Plant Disease Detection"**.

### Step 13 -- Camera Permissions

Verifies the `agrikd` user is in the `video` group for `/dev/video*` access.
Lists connected cameras using `v4l2-ctl` if available.

Supabase sync is optional; the system operates fully offline without it.

---

## Zero-Touch Provisioning

### Prerequisites
- Admin creates a provisioning token on the Dashboard: **Devices -> Provisioning Tokens -> Generate Token**
- Token format: `agrikd://<base64url encoded JSON>` (contains Supabase URL, anon key, token ID, expiry)

### Provisioning Flow
1. Run `setup_jetson.sh` -- it prompts for token at step 8
2. Or manually: `python3 /opt/agrikd/scripts/provision.py agrikd://...`
3. Script validates token -> detects hardware -> registers device -> writes `config/config.json` and `data/device_state.json`
4. Device starts in `unassigned` status, running Local-First (capture + inference + SQLite)
5. Admin assigns user on Dashboard -> next poll cycle syncs all backlog

### Hardware Identity
- `hw_id = SHA-256(MAC:serial)` -- unique per physical device
- Serial fallback chain: device-tree -> DBUS machine-id -> disk UUID
- Re-register blocked for active devices (use `--force` or decommission first)

### device_state.json (single-writer: sync_engine only)

```json
{
  "device_token": "<uuid>",
  "device_id": "<int>",
  "hw_id": "<hash>",
  "user_id": "<uuid or null>",
  "config_version_applied": 0,
  "desired_config": {},
  "reported_config": {}
}
```

---

## 5. GUI Application Guide

The GUI application (`gui_app.py`) provides a complete desktop interface for
plant leaf disease detection. It uses PyQt5 for the user interface, OpenCV for
camera capture, and TensorRT for inference, all running on the Jetson device.

### 5.1 Launching the GUI

> **⚠ Important:** TensorRT and PyCUDA are installed by JetPack for the
> **system Python** (`/usr/bin/python3`) only. If you are in a conda or
> virtualenv environment, the GUI will auto-detect this and re-launch with
> system Python. For best results, use one of the methods below.

**Option A -- Wrapper script (recommended):**

```bash
/opt/agrikd/run_gui.sh
```

The wrapper script always uses `/usr/bin/python3` regardless of your active
Python environment.

**Option B -- Direct command line:**

```bash
/usr/bin/python3 /opt/agrikd/app/gui_app.py
```

To specify a custom configuration file:

```bash
/usr/bin/python3 /opt/agrikd/app/gui_app.py --config /path/to/config.json
```

**Option C -- Desktop shortcut:**

Open the application menu on the Jetson desktop and click
**"AgriKD Plant Disease Detection"**. The shortcut executes the same command as
Option B using the default configuration path (`config/config.json`).

**Option D -- systemd service (auto-start on login):**

```bash
sudo systemctl start agrikd-gui
sudo systemctl enable agrikd-gui   # optional: start on every boot
```

The `agrikd-gui.service` unit sets `DISPLAY=:0` automatically and is configured
with `Restart=always` and `RestartSec=5`, so the GUI automatically restarts
after any crash. Resource limits are enforced: `MemoryMax=512M` and
`CPUQuota=80%`.

### 5.2 Interface Layout

The application window (minimum size: 1080 x 640 pixels) is divided into four
zones:

```
+------------------------------------------------------------------+
|  [Toolbar]  Model: [Tomato v]  |  [Start Camera] / [Stop Camera] |
+------------------------------------------------------------------+
|                          |                                        |
|   Live Camera Preview    |   Results                              |
|      (480 x 360)         |   ------------------------------------ |
|                          |   Predicted class (large green text)   |
|                          |   Confidence: 95.3%                    |
|                          |   Inference: 1.42 ms                   |
|                          |                                        |
|                          |   All Classes                          |
|                          |   +---------------------+----------+   |
|                          |   | Class               | Conf.    |   |
|                          |   +---------------------+----------+   |
|                          |   | Bacterial Spot      | 2.1%     |   |
|                          |   | Early Blight        | 1.3%     |   |
|                          |   | ...                 | ...      |   |
|                          |   | Healthy             | 95.3%    |   |
|                          |   +---------------------+----------+   |
|                          |                                        |
|  [Capture & Analyze]     |   [Analyzed image thumbnail]           |
|  [Load Image File]       |                                        |
+------------------------------------------------------------------+
|  [Status Bar]  Models: tomato, burmese_grape_leaf | Predictions: 42 | Unsynced: 3  |
+------------------------------------------------------------------+
```

**Toolbar** (top): Contains a "Model" dropdown for switching between Tomato and
Burmese Grape Leaf, and a toggle button that reads "Start Camera" when the
camera is off and "Stop Camera" when the camera is running.

**Left panel**: Displays the live camera preview at 480 x 360 pixels with a dark
background. Below the preview are two action buttons: "Capture & Analyze"
(freezes the current frame and runs inference) and "Load Image File" (opens a
file dialog).

**Right panel**: Displays inference results. The predicted class name is shown in
large green text (font size 22, bold). Below it, the confidence percentage and
inference time in milliseconds are displayed. A two-column table lists every
class defined by the currently selected model along with its confidence value.
At the bottom, a thumbnail of the analyzed image is shown.

**Status bar** (bottom): Shows the names of all loaded TensorRT engines, the
total number of predictions made during this session, and the count of
predictions not yet synced to Supabase.

### 5.3 Model Selection

Use the dropdown in the toolbar to switch between available leaf-type models:

- **Tomato** -- 10-class classifier for tomato leaf diseases.
- **Burmese Grape Leaf** -- 5-class classifier for Burmese grape leaf diseases.

Each model uses its own TensorRT engine file (`.engine`). Switching models does
not require restarting the application; all engines are loaded into memory at
startup. If an engine file was not found during startup, selecting that model
will display a warning dialog.

### 5.4 Camera Pre-check

Before launching the GUI, verify that the camera is properly connected and
accessible:

```bash
# List all connected camera devices
v4l2-ctl --list-devices

# Check which video device nodes exist
ls /dev/video*

# Capture a single test frame to verify the camera works
ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 test_frame.jpg

# View the test frame (requires display)
eog test_frame.jpg
```

If `v4l2-ctl --list-devices` returns no output, the camera is not detected.
Check the USB connection or CSI ribbon cable. If device nodes exist but capture
fails, ensure the current user is in the `video` group:

```bash
groups $USER          # should include "video"
sudo usermod -aG video $USER   # if not, add and re-login
```

### 5.5 Camera Operations

> **Camera Warmup:** `capture_single()` in `camera.py` sleeps for `warmup_delay`
> seconds (default 3.0) after opening the camera, then discards `warmup_frames`
> (default 5) frames before capturing. This allows USB/CSI sensors to stabilize
> auto-exposure and white-balance, fixing the "Frame rejected: low entropy" issue.

1. Click **"Start Camera"** to begin the live preview. The camera thread captures
   frames at approximately 30 FPS (33 ms interval) in a background QThread.
2. The preview area updates in real time with the camera feed.
3. Click **"Capture & Analyze"** to freeze the current frame and run TensorRT
   inference. Inference runs in a separate background thread to keep the UI
   responsive.
4. While inference is running, the "Capture & Analyze" and "Load Image File"
   buttons are temporarily disabled to prevent concurrent inference requests.
5. After inference completes, the camera continues streaming. The buttons are
   re-enabled.
6. Click **"Stop Camera"** to halt the live preview and release the camera device.

### 5.6 File Picker

1. Click **"Load Image File"** to open a system file dialog.
2. Supported formats: **JPG, JPEG, PNG, BMP, TIFF**.
3. The selected image is displayed in the preview area and inference runs
   immediately on the loaded image.
4. The file picker can be used with or without the camera running.

### 5.7 Results Display

After each inference, the right panel updates with:

- **Predicted class name** -- displayed in large green text (e.g., "Healthy",
  "Early Blight"). Underscores in class names are replaced with spaces for
  readability.
- **Confidence percentage** -- the softmax probability of the predicted class
  (e.g., "Confidence: 95.3%").
- **Inference time** -- wall-clock time for the TensorRT forward pass in
  milliseconds (e.g., "Inference: 1.42 ms"). This measurement includes
  host-to-device memory transfer, kernel execution, and device-to-host transfer.
- **All-classes table** -- a two-column table listing every class label and its
  confidence value, sorted in the model's original class order (alphabetical
  ImageFolder convention). This allows the operator to see how close secondary
  predictions are to the top prediction.
- **Analyzed image thumbnail** -- a small preview of the image that was analyzed,
  displayed below the table.

### 5.8 Image Capture & Cloud Sync

Every image analyzed through both the API and periodic capture is saved locally
and uploaded to Supabase Storage during the sync cycle:

- **Local storage**: `data/images/` — flat directory.
- **Filename format**: `pred_{unix_ms}_{uuid8}.jpg` (millisecond timestamp +
  8-char UUID to avoid collisions under concurrent requests).
- **Image quality**: JPEG at 85% quality (optimized for upload bandwidth).
- **Cloud sync**: During each sync cycle, the sync engine uploads images to the
  `prediction-images` Supabase Storage bucket at `{user_id}/{ts}_{local_id}.jpg`,
  creates a 365-day signed URL, and stores it in the `image_url` field of the
  `predictions` table. After successful sync the local file is deleted.
- **Retry safety**: If the RPC push fails after image upload, the signed URL is
  persisted in local SQLite (`uploaded_image_url` column) so the next sync cycle
  reuses it instead of re-uploading.
- **Database linkage**: Each prediction record in the SQLite database includes
  an `image_path` column referencing the saved image file, enabling full
  traceability from prediction to source image.
- **Cleanup**: `cleanup_old_records()` deletes orphaned image files for
  predictions older than the retention window.

Over time, this data collection builds a site-specific dataset that captures
real-world conditions (lighting, leaf orientation, camera angle) not present in
the original training set.

---

## 6. Headless REST API Mode

The headless mode runs as a systemd service and exposes a Flask-based REST API
on port 8080. Phase 2 adds rate limiting, upload size enforcement, and MIME
validation to harden the endpoint for production use.

### 6.1 systemd Service

```bash
# Start the service
sudo systemctl start agrikd
sudo systemctl status agrikd

# Enable start on boot (enabled by default after setup)
sudo systemctl enable agrikd

# Stop the service
sudo systemctl stop agrikd
```

The `agrikd.service` unit is configured with `Restart=always` and `RestartSec=10`,
so the service automatically restarts after a crash or OOM kill. Resource limits
(`MemoryMax=512M`, `CPUQuota=80%`) are enforced. The application handles
`SIGTERM` gracefully, releasing the camera and closing the database before exit.

### 6.2 API Endpoints

#### `GET /health`

Returns system status, uptime, loaded models, and database statistics.
When a valid `X-Api-Key` is provided, the response also includes `model_versions`.

```bash
curl http://localhost:8080/health
```

Response (with valid API key):

```json
{
  "status": "healthy",
  "model_versions": {"tomato": "1.0.0", "burmese_grape_leaf": "1.0.0"},
  "models_loaded": ["tomato", "burmese_grape_leaf"],
  "uptime_seconds": 301,
  "database": {
    "total_predictions": 33,
    "synced": 32,
    "unsynced": 1
  }
}
```

Without API key, `model_versions` is omitted:

```json
{
  "status": "healthy",
  "uptime_seconds": 3621,
  "models_loaded": ["tomato", "burmese_grape_leaf"],
  "database": {
    "total_predictions": 142,
    "synced": 130,
    "unsynced": 12,
    "last_prediction": "2026-03-30 14:22:01"
  }
}
```

#### `POST /predict`

Runs inference on an uploaded image. Accepts `multipart/form-data` with two
fields:

- `image` (required) -- the image file.
- `leaf_type` (optional) -- `"tomato"` or `"burmese_grape_leaf"`. Defaults to
  the first available model if omitted.

```bash
curl -X POST http://localhost:8080/predict \
  -F "image=@leaf_photo.jpg" \
  -F "leaf_type=tomato"
```

Response:

```json
{
  "leaf_type": "tomato",
  "prediction": {
    "class_index": 9,
    "class_name": "Healthy",
    "confidence": 0.953,
    "all_confidences": [0.005, 0.008, 0.003, 0.002, 0.001, 0.004, 0.003, 0.012, 0.009, 0.953],
    "inference_time_ms": 1.42
  }
}
```

Error responses return HTTP 400 (bad request), 413 (file too large), 429 (rate
limit exceeded), or 500 (server error) with a JSON body containing an `"error"`
field.

#### `GET /stats`

Returns prediction statistics from the SQLite database.

```bash
curl http://localhost:8080/stats
```

Response:

```json
{
  "total_predictions": 142,
  "synced": 130,
  "unsynced": 12,
  "last_prediction": "2026-03-30 14:22:01"
}
```

### 6.3 Rate Limiting

The `/predict` endpoint enforces a rate limit of **30 requests per minute per
client IP address**. The limiter uses an in-memory sliding-window algorithm with
no external dependencies. When the limit is exceeded, the server returns HTTP 429:

```json
{
  "error": "Rate limit exceeded (30 req/min)"
}
```

Timestamps older than 60 seconds are pruned automatically on each request. All
three endpoints (`/health`, `/predict`, `/stats`) are rate-limited at 30
requests per minute per client IP.

### 6.4 API Key Authentication

The server supports optional API key authentication via the `X-API-Key` header.
When `server.api_key` is set in `config.json`, all endpoints **except `/health`**
require a matching `X-API-Key` header. Requests without the key receive HTTP 401.

```bash
# Example: predict with API key authentication
curl -X POST http://localhost:8080/predict \
  -H "X-API-Key: your-secret-key" \
  -F "image=@leaf_photo.jpg" \
  -F "leaf_type=tomato"
```

If `api_key` is empty (the default), authentication is disabled and all
endpoints are accessible without a key. For production deployments on a shared
network, always set an API key.

### 6.5 Upload Size Limit

Flask's `MAX_CONTENT_LENGTH` is set to **10 MB** (10,485,760 bytes). Any request
body exceeding this size is rejected before the file is fully read, and the
server returns HTTP 413:

```json
{
  "error": "File too large (max 10 MB)"
}
```

### 6.6 MIME Validation

Before processing, the server validates the uploaded file's extension against
an allowlist. Only the following extensions are accepted:

- `jpg`
- `jpeg`
- `png`
- `bmp`
- `tiff`

Files with any other extension (or no extension) are rejected with HTTP 400:

```json
{
  "error": "Invalid file type. Allowed: jpg, jpeg, png, bmp, tiff"
}
```

### 6.7 curl Examples

```bash
# Health check
curl http://localhost:8080/health

# Predict with tomato model
curl -X POST http://localhost:8080/predict \
  -F "image=@leaf_photo.jpg" \
  -F "leaf_type=tomato"

# Predict with burmese_grape_leaf model
curl -X POST http://localhost:8080/predict \
  -F "image=@burmese_leaf.png" \
  -F "leaf_type=burmese_grape_leaf"

# Predict using default model (first available)
curl -X POST http://localhost:8080/predict \
  -F "image=@leaf.jpg"

# View statistics
curl http://localhost:8080/stats
```

---

## 7. Configuration

All runtime behavior is controlled by a single JSON file. The file
`jetson/config/config.json` is **gitignored** and must not be committed to the
repository, because it may contain Supabase credentials or site-specific
settings. Instead, a version-controlled template is provided.

### 7.1 Creating config.json

```bash
cd /opt/agrikd
cp config/config.example.json config/config.json
```

Then edit `config/config.json` to fill in Supabase credentials and adjust any
site-specific settings (camera source, server port, etc.).

### 7.2 Full Configuration Reference

```json
{
    "camera": {
        "source": 0,
        "width": 640,
        "height": 480,
        "mode": "manual"
    },
    "inference": {
        "input_size": 224,
        "imagenet_mean": [0.485, 0.456, 0.406],
        "imagenet_std": [0.229, 0.224, 0.225]
    },
    "models": {
        "tomato": {
            "engine_path": "models/tomato_student.engine",
            "sha256_checksum": "",
            "version": "1.0.0",
            "num_classes": 10,
            "class_labels": [
                "Bacterial_spot", "Early_blight", "Late_blight",
                "Leaf_Mold", "Septoria_leaf_spot", "Spider_mites",
                "Target_Spot", "Yellow_Leaf_Curl_Virus", "Mosaic_virus",
                "Healthy"
            ]
        },
        "burmese_grape_leaf": {
            "engine_path": "models/burmese_grape_leaf_student.engine",
            "sha256_checksum": "",
            "version": "1.0.0",
            "num_classes": 5,
            "class_labels": [
                "Anthracnose", "Healthy", "Insect Damage",
                "Leaf Spot", "Powdery Mildew"
            ]
        }
    },
    "sync": {
        "supabase_url": "",
        "supabase_key": "",
        "email": "",
        "password": "",
        "batch_size": 50,
        "interval_seconds": 300
    },
    "server": {
        "host": "127.0.0.1",
        "port": 8080,
        "api_key": ""
    },
    "database": {
        "path": "data/agrikd_jetson.db"
    },
    "logging": {
        "level": "INFO",
        "file": "logs/agrikd.log",
        "max_bytes": 104857600,
        "backup_count": 5
    }
}
```

### 7.3 `camera`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `source` | int or string | `0` | Camera device index (e.g., `0` for `/dev/video0`) or an RTSP URL |
| `width` | int | `640` | Capture resolution width in pixels |
| `height` | int | `480` | Capture resolution height in pixels |
| `mode` | string | `"manual"` | `"manual"` (API-triggered only) or `"periodic"` (timed capture) |
| `interval_seconds` | int | `1800` | Capture interval in seconds (periodic mode only) |
| `warmup_delay` | float | `3.0` | Seconds to sleep after opening the camera before capturing. Allows USB/CSI sensor auto-exposure and white-balance to stabilize. |
| `warmup_frames` | int | `5` | Number of frames to discard after warmup delay before the actual capture. Ensures the captured frame has stable exposure. |

### 7.4 `inference`

| Key | Type | Description |
|-----|------|-------------|
| `input_size` | int | Input tensor spatial dimension (224 for MobileNetV2) |
| `imagenet_mean` | float[3] | Per-channel mean for ImageNet normalization |
| `imagenet_std` | float[3] | Per-channel standard deviation for ImageNet normalization |

### 7.5 `models`

Each key is a leaf type identifier. The value is an object with:

| Key | Type | Description |
|-----|------|-------------|
| `engine_path` | string | Relative or absolute path to the TensorRT `.engine` file |
| `sha256_checksum` | string | (Optional) SHA-256 hex digest of the `.engine` file. Verified at load time to detect corruption or wrong file. |
| `version` | string | (Optional) Semantic version (e.g., `"2.1.0"`) of the ONNX model this engine was built from. Stored in predictions for traceability. |
| `num_classes` | int | Number of output classes |
| `class_labels` | string[] | Ordered list of class names (must match ImageFolder alphabetical order from training) |

### 7.6 `sync`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `supabase_url` | string | `""` | Supabase project URL. Leave empty to disable sync. |
| `supabase_key` | string | `""` | Supabase anonymous (anon) key. Leave empty to disable sync. |
| `email` | string | `""` | (Optional) Legacy auth: email for JWT authentication. Ignored when using device-token RPC flow. |
| `password` | string | `""` | (Optional) Legacy auth: password for JWT authentication. |
| `batch_size` | int | `50` | Maximum number of predictions to sync per batch |
| `interval_seconds` | int | `300` | Time between sync attempts in seconds (default: 5 minutes) |

### 7.7 `server`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `host` | string | `"127.0.0.1"` | Bind address for the REST API server |
| `port` | int | `8080` | Port number for the REST API server |
| `api_key` | string | `""` | (Optional) Shared secret for API authentication. When set, all `/predict` requests must include `X-Api-Key` header. Leave empty to disable (suitable for LAN-only deployments). |

### 7.8 `database`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `path` | string | `"data/agrikd_jetson.db"` | Path to the SQLite database file (WAL mode enabled) |

### 7.9 `logging`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `level` | string | `"INFO"` | Log level: `DEBUG`, `INFO`, `WARNING`, `ERROR`, or `CRITICAL` |
| `file` | string | `"logs/agrikd.log"` | Path to the log file |
| `max_bytes` | int | `104857600` | Maximum log file size in bytes before rotation (default: 100 MB) |
| `backup_count` | int | `5` | Number of rotated log backups to retain |

---

## 8. Model Management

### 8.1 Adding a New Model

To deploy a new or updated ONNX model to the Jetson:

```bash
# Copy the ONNX file to the models directory
cp new_model.onnx /opt/agrikd/models/

# Convert to TensorRT FP16 engine (must be done on the target Jetson device)
trtexec --onnx=/opt/agrikd/models/new_model.onnx \
        --saveEngine=/opt/agrikd/models/new_model.engine \
        --fp16 \
        --workspace=1024
```

**`trtexec` Path Discovery:** `sync_engine.py` `_build_engine()` searches for
`trtexec` in the following order (fixes "No such file or directory: 'trtexec'"
when running as a systemd service with limited PATH):

1. `shutil.which("trtexec")` — system PATH
2. `/usr/src/tensorrt/bin/trtexec` — JetPack default location
3. `/usr/local/bin/trtexec`
4. `~/trtexec`

**Engine File Naming Convention:** Engine files built by the sync engine are
named `{leaf_type}_student_v{version}.engine`, e.g.,
`tomato_student_v1.1.0.engine`. Old engine files are deleted after a successful
hot-swap to free storage.

Then update `config.json` to add the new model entry under the `models` section
with the correct `engine_path`, `num_classes`, and `class_labels`.

### 8.2 Model Checksum Verification

In farm environments with unreliable internet or when transferring models via
USB drives, always verify file integrity before and after conversion:

```bash
# After downloading or copying the ONNX model, verify integrity
sha256sum /opt/agrikd/models/tomato_student.onnx
# Compare the output hash with the checksum from model_registry.json or GitHub Release

# After TensorRT conversion, record the engine checksum for future reference
sha256sum /opt/agrikd/models/tomato_student.engine
```

### 8.3 Engine Portability

TensorRT engines are **not portable** between different Jetson hardware variants
or TensorRT versions. An engine built on a Jetson Nano will not load on a Jetson
Xavier. Always rebuild engines on the target device using the `trtexec` command
shown above.

---

## 9. Supabase Sync

The sync engine runs as a background daemon thread in both headless and GUI
modes. It periodically pushes locally stored predictions to the Supabase
cloud database and polls for device config updates from the admin dashboard.

### 9.1 Sync Behavior

All device↔Supabase communication uses **RPC functions** (SECURITY DEFINER)
instead of direct REST table queries. This is required because Supabase's
gateway does not forward custom HTTP headers to PostgREST, making header-based
RLS policies ineffective.

**Prerequisite**: Migration `020_device_sync_rpcs.sql` must be applied to
Supabase before sync will work. Run it in the Supabase SQL Editor.

Each sync cycle (every `interval_seconds`, default 300s) performs:

1. **Config poll** — calls `device_poll_config(device_token)` RPC to receive
   `desired_config`, `config_version`, `status`, and `user_id` from the admin
   dashboard.
2. **Prediction push** — calls `device_push_predictions(device_token, predictions)`
   RPC with up to `batch_size` (default: 50) unsynced records from local SQLite.
   Skipped if no user is assigned.
   - **Image upload**: For each prediction with a local `image_path`, the engine
     uploads the JPEG to the `prediction-images` Supabase Storage bucket at
     `{user_id}/{timestamp}_{local_id}.jpg`, creates a 365-day signed URL, and
     includes `image_url` in the prediction payload. After successful sync the
     local file is deleted. If the RPC fails, the uploaded URL is persisted in
     SQLite so retries reuse it (no duplicate uploads). Image upload failure does
     NOT block prediction sync — the prediction is pushed without an image.
3. **Heartbeat** — calls `device_heartbeat(device_token)` RPC to update
   `last_seen_at` and set `status=online` (if a user is assigned).
4. **Config ACK** — when a new config version is detected, applies it locally
   then calls `device_ack_config(device_token, reported_config)` so the
   dashboard shows "Synced" instead of "Pending".

On network error, the current cycle is aborted and retried on the next
interval. Predictions stay safely in local SQLite until synced.
If `supabase_url` or `supabase_key` are empty, sync is silently skipped.

**Retry behavior:**
- **Network errors / 5xx** — transient; retry next cycle without penalty.
- **4xx client errors** (except 401) — each affected prediction's
  `sync_retry_count` is incremented. After **10 failed attempts**, the
  prediction is permanently skipped (`get_unsynced` excludes it). This
  prevents a single corrupted record from blocking the entire sync queue.
- **401 Unauthorized** — triggers re-authentication; retry count is not
  incremented.

**Shutdown draining:** On SIGTERM the sync engine is signalled to stop. The
main thread waits up to 30 seconds for the current sync cycle to complete
before proceeding with shutdown.

### 9.2 Configuring Credentials

Edit `/opt/agrikd/config/config.json` and fill in the `sync` section:

```json
"sync": {
    "supabase_url": "https://your-project-id.supabase.co",
    "supabase_key": "eyJhbGciOiJIUzI1NiIsInR5cCI6...",
    "batch_size": 50,
    "interval_seconds": 300
}
```

Restart the service after changing credentials:

```bash
sudo systemctl restart agrikd
```

### 9.3 GCS Service Account Key

The GCS service account key enables DVC dataset access for on-device TensorRT
validation. Credentials are distributed automatically via the Supabase
`system_secrets` table:

1. **Dashboard upload:** Admin uploads the read-only GCS SA JSON via
   Settings → Integrations. The key is stored in `system_secrets` with key
   `gcs_readonly_key`.
2. **Auto-fetch:** During provisioning or first engine validation, the device
   calls `get_system_secret(device_token, 'gcs_readonly_key')` and saves the
   result to `config/secrets/gcs-readonly.json` (mode 0600).
3. **Env var fallback:** Set `AGRIKD_GCS_KEY_DATA` with the raw JSON content
   for manual provisioning scenarios.

The key file is gitignored and must never be committed. If a key was
previously exposed, rotate it immediately in the Google Cloud Console and
re-upload the new key via the admin dashboard — all devices will pick up the
new credential on next sync.

### 9.4 Monitoring Sync Status

In the GUI, the status bar displays the current unsynced count. In headless
mode, query the `/stats` endpoint or check the logs:

```bash
curl http://localhost:8080/stats
journalctl -u agrikd | grep "Sync complete"
```

### 9.5 Model Version Management (Auto-Engine Build)

The admin dashboard allows assigning specific model versions to each Jetson
device. When the version changes, the sync engine automatically handles the
full lifecycle:

**Dashboard Side** (Admin):
1. Open **Devices** page → Edit device → **Model Versions** section
2. Select a version per leaf_type from the dropdown (shows active/staging models
   from `model_registry`)
3. Save → `desired_config.model_versions` is updated in Supabase

**`desired_config.model_versions` format example:**

```json
{
    "model_versions": {
        "tomato": "2.1.0",
        "burmese_grape_leaf": "1.0.0"
    }
}
```

Each key is a leaf type (matching `model_registry.leaf_type`), and the value
is the semantic version string (matching `model_registry.version`).  Only
`active` or `staging` models appear in the dashboard dropdown.

**Jetson Side** (Automatic):
1. Sync engine polls `desired_config` and detects version change
2. Checks for cached engine in `model_engines` table (same hardware tag)
   - **Hardware tag**: a string like `sm53` (Nano), `sm72` (Xavier), `sm87`
     (Orin) derived from `nvidia-smi --query-gpu=compute_cap` or
     `/proc/device-tree/model`. Engines built on one GPU architecture cannot
     run on another, so caching is per hardware tag.
3. If cached: downloads pre-built engine (fast)
4. If not cached: downloads ONNX from Storage → builds engine with
   `trtexec --fp16` (10–30 min on Jetson) → uploads to cache for others
5. Hot-swaps the engine in `InferenceWorkerPool` without service restart
6. Updates local `config.json` with new version, path, class labels
7. Deletes old engine file to free storage
8. Reports `engine_status` (building/ready/error) + `applied_model_versions`
   in `reported_config`

**Pre-build on Startup:** When `SyncEngine.run()` starts, it immediately
compares `desired_config.model_versions` against loaded engines. If a version
mismatch is detected, it triggers an engine build right away instead of waiting
for the first poll cycle (5 minutes).

**Config Flow (Single Writer Pattern):**

```
Admin Dashboard → Supabase (devices.desired_config.model_versions)
    ↓ (poll every 5 min)
SyncEngine (SINGLE WRITER for device_state.json + config.json)
    ↓ (thread-safe read)
main.py reads via sync.get_active_config()
```

`SyncEngine` is the sole writer of `device_state.json` and `config.json`.
All other components read config through `sync.get_active_config()` which
provides a thread-safe snapshot.

**Status Monitoring**:
- Dashboard table shows per-model engine status: ✅ ready / 🔶 building / 🔴 error
- Edit modal shows detailed engine status per leaf_type
- Config status shows "Synced" only after Jetson ACKs the new config
- Logs: `journalctl -u agrikd | grep -i "engine\|hot-swap\|model version"`

---

## 10. Docker Deployment (REMOVED)

> **⚠️ Docker deployment has been removed.**
> NVIDIA does not provide an official JetPack 6 Docker base image with
> TRT 10.x + Python 3.10. The previous Dockerfile targeted JetPack 5
> (TRT 8.5, Python 3.8, CUDA 11.4) which is incompatible with JetPack 6
> hardware. TensorRT engines are not portable across major versions.
>
> **Use host-native deployment via systemd** (see sections 3–4 above).

---

## 11. Monitoring and Logs

### 11.1 Model Version Logging

Model versions are logged at three points for traceability:

| Event | Example Log Line |
|-------|-----------------|
| **Startup** | `Loaded TensorRT engine: tomato v1.0.0 (models/tomato_student.engine)` |
| **Hot-swap** | `Hot-swapped engine: tomato v1.1.0 → models/tomato_student_v1.1.0.engine` |
| **Prediction** | `Prediction: Late_blight (50.9%) [model=tomato v1.0.0]` |

Filter for version events: `journalctl -u agrikd | grep -i "engine\|hot-swap\|model version"`

### 11.2 Headless Service Logs

```bash
# Follow live logs from the systemd journal
journalctl -u agrikd -f

# View the last 100 lines
journalctl -u agrikd -n 100 --no-pager
```

### 11.3 GUI Application Logs

The GUI application uses Python's `RotatingFileHandler` to write logs to
`logs/agrikd_gui.log`:

```bash
# Follow the GUI log file in real time
tail -f /opt/agrikd/logs/agrikd_gui.log
```

The log format is: `%(asctime)s [%(levelname)s] %(name)s: %(message)s`

Log entries include engine loading, camera start/stop events, inference results
(leaf type, class, confidence, time, image path), and errors.

### 11.4 Log Rotation

Both the headless and GUI applications use Python's `RotatingFileHandler`:

- **Maximum file size**: 100 MB per log file (`max_bytes: 104857600`).
- **Backup count**: 5 rotated files are retained.
- **Total maximum disk usage**: approximately 600 MB per application (1 active +
  5 backups).

These values can be adjusted in the `logging` section of `config.json` (headless)
or by modifying the `RotatingFileHandler` parameters in `gui_app.py` (GUI).

### 11.5 systemd Resource Limits

Both service unit files enforce resource limits to prevent the inference
application from starving other processes on the Jetson:

**`agrikd.service` (headless):**

| Directive | Value | Description |
|-----------|-------|-------------|
| `Restart` | `always` | Automatically restart after any exit |
| `RestartSec` | `10` | Wait 10 seconds before restarting |
| `MemoryMax` | `512M` | Maximum resident memory for the service |
| `CPUQuota` | `80%` | Maximum CPU time as a percentage of one core |

**`agrikd-gui.service` (GUI):**

| Directive | Value | Description |
|-----------|-------|-------------|
| `Restart` | `always` | Automatically restart after any exit |
| `RestartSec` | `5` | Wait 5 seconds before restarting |
| `MemoryMax` | `512M` | Maximum resident memory for the service |
| `CPUQuota` | `80%` | Maximum CPU time as a percentage of one core |

To adjust these limits, edit the corresponding `.service` file in
`/etc/systemd/system/` and reload:

```bash
sudo systemctl daemon-reload
sudo systemctl restart agrikd
```

---

## 12. TLS Termination (HTTPS)

The headless REST API (Section 6) runs on plain HTTP by default. For
production deployments exposed to untrusted networks, add a TLS reverse proxy
in front of the Flask server so that all traffic between clients and the Jetson
is encrypted.

### 12.1 Nginx Reverse Proxy Configuration

Create `/etc/nginx/sites-available/agrikd`:

```nginx
server {
    listen 443 ssl;
    server_name agrikd.local;

    ssl_certificate     /etc/ssl/certs/agrikd.crt;
    ssl_certificate_key /etc/ssl/private/agrikd.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 10M;
    }
}
```

### 12.2 Quick Setup

```bash
# 1. Install Nginx
sudo apt-get update && sudo apt-get install -y nginx

# 2. Generate a self-signed certificate (valid for 365 days)
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/agrikd.key \
    -out /etc/ssl/certs/agrikd.crt \
    -subj "/CN=agrikd.local"

# 3. Copy the site configuration
sudo cp agrikd /etc/nginx/sites-available/agrikd
sudo ln -sf /etc/nginx/sites-available/agrikd /etc/nginx/sites-enabled/

# 4. Test configuration and restart Nginx
sudo nginx -t
sudo systemctl restart nginx
```

After setup, the API is available at `https://agrikd.local/health` (port 443).
The upstream Flask server continues to listen on `127.0.0.1:8080` and should
**not** be exposed directly to the network. Use a firewall rule to block
external access to port 8080:

```bash
sudo ufw deny 8080
sudo ufw allow 443
```

### 12.3 When Is TLS Required?

- **LAN-only deployments behind a firewall** -- TLS is optional. The Jetson and
  its clients reside on a trusted private network, and the overhead of
  certificate management may not be justified.
- **Internet-facing or multi-tenant deployments** -- TLS is **mandatory**.
  Without encryption, prediction images and API keys transit the network in
  plaintext.

For publicly reachable deployments, replace the self-signed certificate with one
issued by a trusted CA (e.g., Let's Encrypt).

---

## 13. Troubleshooting

| Problem | Solution |
|---------|----------|
| **"TensorRT or PyCUDA not installed"** | You are likely running from a **conda or virtualenv** Python which does not have JetPack libraries. Use `/opt/agrikd/run_gui.sh` or `/usr/bin/python3` directly. The GUI will attempt auto-detection and re-launch with system Python, but if that fails, deactivate conda first: `conda deactivate && /usr/bin/python3 /opt/agrikd/app/gui_app.py`. |
| **TensorRT engine fails to load** | TensorRT engines are hardware-specific. Rebuild the engine on the target Jetson device using `trtexec`. An engine built on one Jetson variant (e.g., Nano) will not load on another (e.g., Xavier). |
| **Camera not found** | Run `v4l2-ctl --list-devices` to list connected cameras. Verify the USB cable is securely connected. For CSI cameras, check the ribbon cable and ensure it is properly seated in the connector. |
| **GUI does not display** | Ensure the `DISPLAY` environment variable is set: `export DISPLAY=:0`. Verify the X server is running with `xdpyinfo`. If using SSH, enable X forwarding with `ssh -X`. |
| **Out of memory during inference** | Reduce the `--workspace` value when building the TensorRT engine. Check `MemoryMax` in the systemd service file and increase if necessary. Run `tegrastats` to monitor real-time memory usage. |
| **Sync failing silently** | Verify that `supabase_url` and `supabase_key` are correctly set in `config.json`. Test connectivity with `curl <supabase_url>/rest/v1/` from the Jetson. Check logs for HTTP status codes. |
| **Permission denied on `/dev/video*`** | Run `sudo usermod -aG video $USER` and then log out and log back in for the group change to take effect. Verify with `groups $USER`. |
| **Slow or laggy camera preview** | Lower the camera resolution in `config.json` (e.g., 640x480 instead of 1920x1080). Check that no other application is using the camera device. Use a USB 3.0 port if available. |
| **"No Frame" dialog when clicking Capture** | The camera has not been started. Click "Start Camera" first, or use "Load Image File" to analyze a static image. |
| **Database locked errors** | The SQLite database uses WAL mode and a 5-second busy timeout. If errors persist, ensure only one instance of the application (headless or GUI) is running at a time. |
| **"Frame rejected: low entropy"** | Camera auto-exposure/white-balance not stabilized. `capture_single()` warmup handles this automatically (`warmup_delay=3.0`, `warmup_frames=5`). Increase `warmup_delay` in `config.json` if the issue persists with slow-starting cameras. |
| **"No such file or directory: 'trtexec'"** | Occurs when running as systemd service with limited PATH. `sync_engine.py` now searches multiple paths automatically. If `trtexec` is in a non-standard location, symlink it to `/usr/local/bin/trtexec`. |
| **Engine conversion fails with `trtexec`** | Ensure JetPack SDK is fully installed. Run `dpkg -l \| grep tensorrt` to verify TensorRT packages. Check that the ONNX model was exported with opset 11 or higher. |
| **HTTP 413 on `/predict`** | The uploaded file exceeds the 10 MB limit. Resize or compress the image before uploading. |
| **HTTP 429 on `/predict`** | The client IP has exceeded 30 requests per minute. Wait 60 seconds before retrying or reduce request frequency. |
| **"Invalid file type" on `/predict`** | Only jpg, jpeg, png, bmp, and tiff extensions are accepted. Rename or convert the file to a supported format. |
| **`config.json` not found after git clone** | The file `jetson/config/config.json` is gitignored. Copy from the template: `cp config/config.example.json config/config.json`. |
| **GCS service account key missing** | Set `GOOGLE_APPLICATION_CREDENTIALS` env var pointing to the SA JSON key, or place it as `.dvc/gcs-sa.json`. Obtain the key from Google Cloud Console. If previously exposed in git history, rotate the key immediately. |

---

## Appendix: File Structure

```
/opt/agrikd/
  app/
    main.py              # Headless entry point
    gui_app.py           # GUI entry point (RotatingFileHandler -> logs/agrikd_gui.log)
    inference.py         # TensorRT inference engine
    camera.py            # USB/CSI camera capture
    database.py          # SQLite database (WAL mode)
    health_server.py     # Flask REST API (/health, /predict, /stats)
                         #   - Rate limit: 30 req/min per IP (429)
                         #   - Upload limit: 10 MB (413)
                         #   - MIME validation: jpg, jpeg, png, bmp, tiff
                         #   - API key authentication (X-API-Key header)
    sync_engine.py       # Background Supabase sync + device config polling
  scripts/
    provision.py         # Zero-Touch Provisioning CLI (decode token, register, write config)
  config/
    config.example.json  # Version-controlled template (committed to git)
    config.json          # Site-specific config (GITIGNORED — copy from example)
  models/
    tomato_student.engine                # or tomato_student_v1.0.0.engine (versioned by sync engine)
    burmese_grape_leaf_student.engine     # or burmese_grape_leaf_student_v1.0.0.engine
  data/
    agrikd_jetson.db     # SQLite database file
    device_state.json    # Device registration state (GITIGNORED, chmod 600)
    images/
      tomato/            # Active Learning images (tomato)
      burmese_grape_leaf/  # Active Learning images (burmese grape leaf)
  logs/
    agrikd.log           # Headless service log (RotatingFileHandler, 100 MB x 5)
    agrikd_gui.log       # GUI application log (RotatingFileHandler, 100 MB x 5)
```
