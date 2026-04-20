# AgriKD — System Technical Reference

> Single source of truth for all technical details.
> Last verified: 2026-04-16.

---

## 1. Project Overview

**AgriKD** (Agricultural Knowledge Distillation) is a plant leaf disease recognition
system built on Knowledge Distillation. A ViT-Base teacher distills into a truncated
MobileNetV2 student optimized for real-time inference on mobile and edge devices.

| Property | Value |
|---|---|
| Distillation pair | ViT-Base (teacher) → Truncated MobileNetV2 (student) |
| Tomato dataset | 10 disease/healthy classes |
| Burmese Grape Leaf dataset | 5 disease/healthy classes |
| Design philosophy | Zero-cost infrastructure, offline-first operation |
| Model-per-leaf | Each leaf type has a separate .pth checkpoint trained on its own dataset |

Four deployment targets: Flutter mobile app (`mobile_app/`), Supabase cloud backend,
React admin dashboard (`admin-dashboard/`), and Jetson edge inference station (`jetson/`).
All model artifacts are produced by a single MLOps pipeline and versioned with DVC.

---

## 2. System Architecture

```
+-------------------------------------------------------------+
|                      Cloud Layer (Supabase)                  |
|  PostgreSQL  |  Auth (PKCE)  |  Storage  |  REST API         |
+------+-----------+-------------------+----------+------------+
       |           |                   |          |
       v           v                   v          v
+-------------+  +------------------+  +-------------------+
| Flutter App |  | React Admin      |  | Jetson Edge       |
| (Android)   |  | Dashboard        |  | Device            |
| mobile_app/ |  | (Vercel)         |  |                   |
|             |  |                  |  | TensorRT FP16     |
| TFLite      |  | Users, Models,   |  | PyQt5 GUI         |
| Inference   |  | Predictions,     |  | Flask REST API    |
| SyncQueue   |  | Releases, Health |  |   Rate-limited    |
| SQLite      |  | @sentry/react    |  |   MIME-validated  |
| sentry_     |  | Security headers |  | SyncEngine        |
|  flutter    |  +------------------+  | SQLite            |
+------+------+                        +--------+----------+
       |                                        |
       +----------------+-----------------------+
                        |
              +---------+---------+
              | MLOps Pipeline    |
              | PTH -> ONNX ->   |
              |   TFLite / TRT   |
              | DVC + GH Actions |
              +-------------------+
                        |
              +---------+---------+
              | database/         |
              | verify_rls_       |
              |  policies.sql     |
              | (IaC RLS audit)   |
              +-------------------+
```

---

## 3. Technology Stack

| Layer | Technology | Version / Notes |
|---|---|---|
| Mobile Framework | Flutter + Dart | SDK ^3.11.1 |
| State Management | Riverpod (flutter_riverpod) | ^2.6.1 |
| ML Inference (Mobile) | tflite_flutter | ^0.12.1 |
| Error Tracking (Mobile) | sentry_flutter | ^9.16.1 |
| ML Inference (Edge) | TensorRT FP16 | JetPack r8.5.2 |
| Edge GUI | PyQt5 | System package |
| Edge REST API | Flask | Rate-limited (30 req/min), 10 MB upload limit |
| Backend | Supabase (PostgreSQL + Auth + Storage) | Managed |
| Admin Dashboard | React 18 + Vite 6 | SPA on Vercel |
| Error Tracking (Dashboard) | @sentry/react | ^10.47.0 |
| MLOps Runtime | Python 3.10 + DVC + GitHub Actions | venv at `venv_mlops/` |
| Edge Hardware | NVIDIA Jetson (ARM64) | JetPack 6.x, host-native |
| Local Database | SQLite (sqflite 2.4.1 / Python sqlite3) | - |
| Authentication | Supabase Auth + Google Sign-In 6.2.1 | PKCE flow |
| IaC Audit | PL/pgSQL (verify_rls_policies.sql) | Run in SQL Editor |

---

## 4. Repository Structure

```
agrikd/
├── mobile_app/                        # Flutter app (Clean Architecture + Riverpod)
│   ├── lib/                           # Dart source (59 files)
│   │   ├── core/
│   │   │   ├── config/                # EnvConfig, SupabaseConfig
│   │   │   ├── constants/             # AppConstants, ModelConstants
│   │   │   ├── l10n/                  # Dual-language strings (EN / VI)
│   │   │   ├── theme/                 # AppTheme (light + dark)
│   │   │   └── utils/                 # ImagePreprocessor, ModelIntegrity, FileHelper
│   │   ├── data/
│   │   │   ├── database/              # AppDatabase, DAOs (prediction, model, preference)
│   │   │   └── sync/                  # SyncQueue, SupabaseSyncService
│   │   ├── features/
│   │   │   ├── auth/                  # Login, Register, ForgotPassword, ResetPassword
│   │   │   ├── devices/               # Device list, config editor (Jetson fleet)
│   │   │   ├── diagnosis/             # Home, Camera, Result screens + TFLite service
│   │   │   ├── history/               # History list, Detail, Stats screens
│   │   │   └── settings/              # Settings, Benchmark screens
│   │   └── providers/                 # Riverpod providers
│   ├── assets/models/                 # Bundled TFLite models (~0.96 MB each)
│   ├── test/                          # 144 tests across 14 test files
│   ├── pubspec.yaml                   # Flutter dependencies
│   └── .env                           # Local dev env (generated by sync_env.py)
│
├── admin-dashboard/                   # React + Vite admin panel
│   └── src/
│       ├── pages/                     # 11 pages: Dashboard, Users, Models, Predictions,
│       │                              #   Releases, DataManagement, SystemHealth,
│       │                              #   Settings, ModelReports, Devices, Login
│       ├── components/                # Layout, ConfirmDialog, CustomTooltip, ErrorBoundary
│       └── lib/                       # Supabase client, helpers
│   ├── vite.config.js                 # Security headers (X-Frame-Options, etc.)
│   └── package.json                   # Includes @sentry/react
│
├── jetson/                            # Edge inference station
│   ├── app/                           # main.py, gui_app.py, inference.py, camera.py,
│   │                                  #   database.py, sync_engine.py, health_server.py,
│   │                                  #   engine_builder.py
│   ├── scripts/
│   │   └── provision.py               # Zero-Touch Provisioning CLI
│   ├── config/
│   │   ├── config.example.json        # Template (committed)
│   │   └── config.json                # Runtime config (gitignored)
│   ├── setup_jetson.sh                # First-boot provisioning
│   ├── agrikd.service                 # systemd unit (headless)
│   └── agrikd-gui.service             # systemd unit (GUI)
│
├── mlops_pipeline/                    # Model conversion & evaluation
│   ├── scripts/
│   │   ├── model_definition.py        # Student model architecture
│   │   ├── convert_pth_to_onnx.py
│   │   ├── convert_onnx_to_tflite.py
│   │   ├── convert_pth_to_tflite.py   # ai-edge-torch (Linux only)
│   │   ├── convert_onnx_to_tensorrt.py
│   │   ├── validate_models.py
│   │   ├── evaluate_models.py
│   │   └── run_pipeline.py            # Orchestrator (--config driven)
│   ├── configs/
│   │   ├── tomato.json
│   │   ├── burmese_grape_leaf.json
│   │   └── model_registry.json
│   └── requirements*.txt              # Separate requirement files per stage
│
├── database/                          # Infrastructure-as-Code DB scripts
│   ├── migrations/                    # 23 SQL migration files (001-023)
│   │   ├── 001_tables.sql
│   │   ├── 002_functions_triggers.sql
│   │   ├── 003_rls_policies.sql
│   │   ├── 004_indexes.sql
│   │   ├── 005_storage.sql
│   │   ├── 006_model_reports_and_rpcs.sql
│   │   ├── 007_multi_version.sql
│   │   ├── 008_cleanup_and_realtime.sql
│   │   ├── 009_security_hardening.sql
│   │   ├── 010_fix_lifecycle_for_update.sql
│   │   ├── 011_dvc_operations.sql
│   │   ├── 012_devices.sql            # Device management: provisioning_tokens, devices, RLS
│   │   ├── 013_model_engines.sql      # Model engines table (TensorRT), engine RPCs
│   │   ├── 014_audit_fixes.sql        # Admin guards on dashboard RPCs
│   │   ├── 015_audit_log_cleanup.sql  # audit_log schema normalization
│   │   ├── 016_fk_constraints.sql     # FK: model_benchmarks + model_versions → model_registry
│   │   ├── 017_dataset_delete.sql     # Extend dvc_operations for dataset deletion
│   │   ├── 018_provision_device_rpc.sql # Atomic provision_device RPC
│   │   ├── 019_engine_upload_policy.sql # Storage policy for TensorRT engine uploads
│   │   ├── 020_device_sync_rpcs.sql   # Device sync RPCs: poll, ack, heartbeat, push
│   │   ├── 021_tensorrt_benchmark_format.sql # Add tensorrt_fp16 to benchmarks format CHECK
│   │   ├── 022_system_secrets.sql     # system_secrets table + get_system_secret RPC
│   │   └── 023_benchmark_upload_policy.sql # RLS policy for Jetson benchmark uploads
│   ├── verify_all_migrations.sql
│   └── verify_rls_policies.sql        # RLS audit
│
├── .github/workflows/                 # CI/CD (13 workflow files)
│   ├── ci.yml                         # Lint, test, build APK, dashboard tests, Jetson lint
│   ├── codeql.yml                     # CodeQL SAST security scanning (JS/TS, Python)
│   ├── release.yml                    # Tagged release build + GitHub Release
│   ├── model-pipeline.yml             # Full convert + validate + upload
│   ├── model-rollback.yml             # Rollback model version in registry
│   ├── deploy.yml                     # Vercel deploy for admin dashboard
│   ├── train.yml                      # Run model training
│   ├── validate-model.yml             # Cross-format validation only
│   ├── dvc-pull.yml                   # Pull datasets from DVC remote
│   ├── dvc-push.yml                   # Push datasets to DVC remote
│   ├── export-data.yml                # Export prediction records
│   ├── dataset-upload.yml             # Upload datasets to storage (staging + DVC)
│   └── dataset-delete.yml             # Delete dataset from DVC + GCS cleanup
├── .github/scripts/
│   └── stage_dataset_to_storage.py    # Stage dataset ZIP to Supabase Storage
│
├── docs/                              # Project documentation
├── data/                              # DVC-tracked datasets (gitignored)
├── model_checkpoints_student/         # KD-trained .pth checkpoints (gitignored)
├── models/                            # Converted ONNX + TFLite outputs (gitignored)
├── sync_env.py                        # Centralized .env sync
├── setup_dev.sh / setup_windows_dev.bat
└── .env.example                       # Environment variable template
```

---

## 5. Model Architecture

### 5.1 Student Network

| Component | Detail |
|---|---|
| Backbone | MobileNetV2 `features[0:12]` (truncated from 19 blocks) |
| Backbone output | 96 channels |
| Pooling | Adaptive Average Pooling → `[batch, 96]` |
| Classifier | `96 → 512 → ReLU → Dropout(0.3) → 256 → ReLU → Dropout(0.3) → N` |
| Input | 224 x 224 x 3, ImageNet normalization |
| Output | Raw logits `[batch, N]` (softmax applied at inference time) |

### 5.2 Input Specification

| Property | Value |
|---|---|
| Input size | 224 x 224 |
| Channels | 3 (RGB) |
| Normalize mean | [0.485, 0.456, 0.406] |
| Normalize std | [0.229, 0.224, 0.225] |
| Format (PyTorch/ONNX) | NCHW |
| Format (TFLite) | NHWC (onnx2tf auto-convert) |

### 5.3 Pre-processing Pipeline (PyTorch reference)

```python
transform = transforms.Compose([
    transforms.Resize((224, 224)),
    transforms.ToTensor(),           # HWC [0,255] -> CHW [0,1]
    transforms.Normalize(
        mean=[0.485, 0.456, 0.406],
        std=[0.229, 0.224, 0.225]
    )
])
```

Flutter replicates this exactly. `ToTensor()` divides by 255.0 and converts HWC→CHW.
TFLite input is NHWC so no axis conversion is needed, only normalization.

### 5.4 Benchmark Results

| Dataset | Top-1 Accuracy | TFLite Size |
|---|---|---|
| Tomato (10 classes) | 87.2% | ~0.96 MB |
| Burmese Grape Leaf (5 classes) | 87.3% | ~0.96 MB |

---

## 6. Class Mappings

Class indices are determined by alphabetical sort of folder names (PyTorch `ImageFolder`
convention). These are encoded identically in MLOps configs, Flutter constants, and Jetson
config.

### 6.1 Tomato (10 classes)

| Index | Class Name | Dataset Folder | Vietnamese |
|---|---|---|---|
| 0 | Bacterial Spot | `Tomato___Bacterial_spot` | Dom vi khuan |
| 1 | Early Blight | `Tomato___Early_blight` | Suong mai som |
| 2 | Late Blight | `Tomato___Late_blight` | Suong mai muon |
| 3 | Leaf Mold | `Tomato___Leaf_Mold` | Moc la |
| 4 | Septoria Leaf Spot | `Tomato___Septoria_leaf_spot` | Dom la Septoria |
| 5 | Spider Mites | `Tomato___Spider_mites Two-spotted_spider_mite` | Nhen do hai cham |
| 6 | Target Spot | `Tomato___Target_Spot` | Dom dich |
| 7 | Yellow Leaf Curl Virus | `Tomato___Tomato_Yellow_Leaf_Curl_Virus` | Virus xoan vang la |
| 8 | Mosaic Virus | `Tomato___Tomato_mosaic_virus` | Virus kham |
| 9 | Healthy | `Tomato___healthy` | Khoe manh |

### 6.2 Burmese Grape Leaf (5 classes)

| Index | Class Name | Dataset Folder | Vietnamese |
|---|---|---|---|
| 0 | Anthracnose (Brown Spot) | `Anthracnose (Brown Spot)` | Than thu - Dom nau |
| 1 | Healthy | `Healthy` | Khoe manh |
| 2 | Insect Damage | `Insect Damage` | Hu hai do con trung |
| 3 | Leaf Spot (Yellow) | `Leaf Spot (Yellow)` | Dom vang la |
| 4 | Powdery Mildew | `Powdery Mildew` | Phan trang |

---

## 7. Data Flows

### 7.1 Training Pipeline

```
Raw Images (DVC)
    |
    v
ViT-Base Teacher (pretrained)
    |  Knowledge Distillation (KL Divergence + CE Loss)
    v
MobileNetV2 Student (.pth checkpoint)
```

### 7.2 Model Conversion Pipeline

```
.pth checkpoint
    |
    +--> convert_pth_to_onnx.py ----> .onnx
    |                                    |
    |                    +---------------+---------------+
    |                    |                               |
    |          convert_onnx_to_tflite.py    convert_onnx_to_tensorrt.py
    |                    |                               |
    |                    v                               v
    |              .tflite (float32)              .engine (FP16)
    |              .tflite (float16)              (Jetson only)
    |                    |
    +--> validate_models.py  (cross-format accuracy check)
    +--> evaluate_models.py  (Top-1 accuracy on test set)
```

All scripts accept a `--config` flag pointing to a per-leaf JSON configuration file.
`convert_pth_to_tflite.py` (ai-edge-torch) only works on Linux.

**Evaluation test split modes:**
- **Standard (no fold):** Stratified split with seed=42: 70% train / 10% val / 20% test
- **Fold-aware (`--fold N`):** StratifiedKFold(n_splits=5, seed=42), fold N as test set (~20%)
- Fold is encoded in version string: `v1.2.3-fold5`. Jetson parses this to use the same split.
- Both CI pipeline (`evaluate_models.py`) and Jetson (`validate_engine.py`) support fold-aware evaluation.

### 7.3 Mobile Inference (Flutter)

```
Camera / Gallery Image
    |
    v
RGBA/Grayscale → RGB conversion (image.convert())
    |
    v
Resize to 224x224 + ImageNet normalization
    mean = [0.485, 0.456, 0.406]
    std  = [0.229, 0.224, 0.225]
    |
    v
TFLite Interpreter (GPU → XNNPack → CPU delegate fallback)
    |
    v
Softmax over logits → class probabilities
    |
    v
Result Screen (top prediction + probability bar chart)
    |
    v
SQLite (predictions table) → SyncQueue → Supabase REST
    |
    v
Sentry (sentry_flutter) captures unhandled exceptions
```

Inference runs inside a Dart `compute()` isolate to keep the UI thread responsive.

### 7.4 Jetson Edge Inference

```
USB Camera / Image File
    |
    v
InferenceWorkerPool (TensorRT FP16, dedicated CUDA thread)
    |
    v
PyQt5 GUI display + SQLite logging  ← LOCAL-FIRST (never blocked by network)
    |
    v
SyncEngine → Supabase REST (when online, best-effort push)
    |
    v
Device Config Poll → Device Shadow (desired_config / reported_config)
```

**Local-First, Cloud-Sync** architecture:
- **InferenceWorkerPool**: Single worker thread owns CUDA context and all TensorRT buffers. All callers submit jobs via `queue.Queue`, receive results via `concurrent.futures.Future`.
- **SQLite thread-safety**: Single `threading.Lock` serializes all DB operations.
- **Wake-Capture-Sleep**: In periodic mode, camera opens/captures/releases per cycle. `capture_single()` applies warmup (3.0s delay, 5 frames) for USB/CSI auto-exposure stabilization.
- **SyncEngine** daemon thread handles cloud sync, device config polling, and heartbeats.
- If no user is assigned (`user_id = NULL`), predictions queue in SQLite. On assignment, the full backlog is synced.
- **Device Shadow**: Admin sets `desired_config` (mode, interval, leaf type, model versions) via the dashboard. The Jetson polls for config changes, applies them, reports `reported_config`. `config_version` auto-increments on each change.
- **Config Flow (Single-Writer)**: `SyncEngine` is the single writer for `device_state.json` and `config.json`; `main.py` reads config via `sync.get_active_config()` (thread-safe, no network call).
- **Model Version Management**: Admin assigns specific model versions per leaf_type to each device. The sync engine checks local engine files first, then queries cached TensorRT engines (if available for the same hardware tag), or downloads ONNX + builds engine sequentially with `trtexec --fp16 --memPoolSize=workspace:1024M`. Engine files use versioned naming: `{leaf_type}_student_v{version}.engine`. Hardware tag format: `{hw_model}_trt{trt_version}` (e.g., `jetson-orin-nx-8gb_trt10.3.0.30`); derived from `/proc/device-tree/model` + `dpkg -l tensorrt`. Cloud storage path (in `models` bucket): `engines/{leaf_type}/{version}/{hw_tag}.engine`. Engines are hot-swapped without service restart. Build status (`building`/`ready`/`error`) reported in `reported_config`. Multiple model builds are serialized via a queue to prevent GPU OOM on memory-constrained Jetson devices.
- **trtexec discovery**: `PATH` → `/usr/src/tensorrt/bin/trtexec` → `/usr/local/bin/trtexec` → `~/trtexec`. Note: `--workspace` was removed in TRT 10.x; use `--memPoolSize=workspace:<N>M` instead (single-char suffix only).
- **Model Version Logging**: Versions logged at startup, on hot-swap, and with each prediction using `[model=leaf_type vX.Y.Z]`.

### 7.5 Jetson REST API Hardening

The Flask API (`health_server.py`) enforces:

| Measure | Detail |
|---|---|
| Server bind | `host=0.0.0.0` (all interfaces, LAN accessible), port 8080 |
| Rate limiting | 30 req/min per IP (in-memory sliding window) |
| Upload size | 10 MB maximum |
| MIME validation | jpg, jpeg, png, bmp, tiff only |
| API key auth | `X-API-Key` header validated against `server.api_key` in config |
| Health endpoint | `/health` returns `model_versions` dict when authenticated |
| Error handler | Structured JSON for 413 responses |

Endpoints: `GET /health`, `POST /predict`, `GET /stats`.

### 7.6 Zero-Touch Provisioning

> **⚠ MANDATORY:** Device provisioning is now **required** for Jetson setup.
> The setup script will fail without a valid provisioning token.

A single `agrikd://` token (generated by Admin Dashboard → Devices → Provisioning
Tokens) configures Supabase credentials, registers hardware identity
(`hw_id = SHA-256(MAC:serial)[:32]`), fetches GCS credentials, and downloads
assigned models automatically.

| Component | Description |
|-----------|-------------|
| `setup_jetson.sh` | Requires token via `AGRIKD_PROVISION_TOKEN` env or interactive prompt |
| `provision.py` | CLI script for registration (supports `--force` and `--file` flags) |
| `provision_device` RPC | Atomic Supabase function for token validation and device registration |

**Provisioning creates:**
- `config.json` with embedded Supabase credentials
- `device_state.json` with device_token for cloud sync
- GCS credentials (if configured) for DVC validation

**Model Download Logic (Step 9):**
1. Query assigned model versions from `device_poll_config` RPC
2. Download exact assigned versions (or fallback to active if unavailable)
3. Try pre-built TensorRT engine, else download ONNX for local conversion

### 7.7 Synchronization

Both Flutter and Jetson maintain local queues of unsynchronized predictions. When
connectivity is detected, the queue is flushed to Supabase REST. Conflict resolution
uses last-write-wins with server-side timestamps.

Jetson sync uploads prediction images to `prediction-images` Storage bucket.
The stored `image_url` field contains a plain storage path (e.g., `prediction-images/{userId}/{ts}_{id}.jpg`) —
NOT a signed URL. The admin dashboard re-signs on demand via `createSignedUrl()`.
After successful sync, local images are deleted.

### 7.8 Environment Variable Distribution

Root `.env` is the single source of truth. `python sync_env.py` distributes:

| Target | Output Path | Notes |
|---|---|---|
| Flutter app | `mobile_app/.env` | Filtered copy (mobile-safe keys only: SUPABASE_URL, SUPABASE_ANON_KEY, GOOGLE_WEB_CLIENT_ID, SENTRY_DSN) |
| Admin dashboard | `admin-dashboard/.env` | Re-prefixed as `VITE_SUPABASE_URL`, etc. |
| Jetson config | `jetson/config/config.json` | Injects into `sync` block |

In CI, Flutter builds receive secrets via `--dart-define` flags.

---

## 8. Flutter App

### 8.1 Architecture

Clean Architecture + Riverpod state management.

```
lib/
├── core/           # Config, Constants, L10n, Theme, Utils
├── data/           # Database (SQLite), Sync services
├── features/       # 5 feature modules (auth, devices, diagnosis, history, settings)
│   └── <feature>/
│       └── presentation/screens/   # Screen widgets
└── providers/      # Riverpod providers
```

### 8.2 Screens (13)

| Feature | Screens |
|---|---|
| Diagnosis | HomeScreen, CameraScreen, ResultScreen |
| History | HistoryScreen, DetailScreen, StatsScreen |
| Settings | SettingsScreen, BenchmarkScreen |
| Devices | DevicesScreen |
| Auth | LoginScreen, RegisterScreen, ForgotPasswordScreen, ResetPasswordScreen |

Plus 3 conditional variants: `camera_screen_mobile.dart`, `camera_screen_stub.dart`, `tflite_inference_service_stub.dart`.

### 8.3 Key Dependencies (pubspec.yaml)

| Package | Version | Purpose |
|---|---|---|
| flutter_riverpod | ^2.6.1 | State management |
| tflite_flutter | ^0.12.1 | TFLite inference |
| sqflite | ^2.4.1 | SQLite database |
| supabase_flutter | ^2.9.0 | Backend client (Auth + DB + Storage) |
| google_sign_in | ^6.2.1 | Native Google auth |
| sentry_flutter | ^9.16.1 | Error tracking |
| camera | ^0.11.0+2 | Camera preview |
| image_picker | ^1.1.2 | Gallery picker |
| image | ^4.3.0 | Image processing |
| connectivity_plus | ^6.1.0 | Network detection |
| path_provider | ^2.1.0 | Local file paths |
| permission_handler | ^11.3.1 | Runtime permissions |
| fl_chart | ^0.69.2 | Charts |
| intl | ^0.19.0 | Date formatting |
| crypto | ^3.0.6 | SHA-256 checksums |
| cupertino_icons | ^1.0.9 | iOS-style icons |
| shared_preferences | ^2.5.5 | Simple key-value storage |
| flutter_dotenv | ^6.0.0 | .env loading (dev mode) |
| sqflite_common_ffi_web | ^1.1.1 | Web SQLite support |

Dart SDK constraint: `^3.11.1`.

### 8.4 TFLite Integration

- Delegate fallback chain: GPU → XNNPack → CPU
  - NnApiDelegate not available in tflite_flutter 0.12.1
  - Preferred delegate cached in user_preferences to skip retry next time
- Inference runs in a Dart `compute()` isolate
- Models bundled in `assets/models/<leaf_type>/<leaf_type>_student.tflite`
- Model integrity verified via SHA-256 before interpreter load
- Image preprocessing: RGBA→RGB conversion, resize 224x224, ImageNet normalization

### 8.5 Auth Flow

Email + Google Sign-In + Forgot/Reset Password, all via Supabase Auth with PKCE.

```
App opens → Check auth state
  ├─ Logged in → HomeScreen (sync enabled)
  └─ Not logged in → HomeScreen (offline mode, login prompt in Settings)
```

Deep link: `com.agrikd.app://callback` (for email confirmation and password reset).

### 8.6 Build Configuration

| Setting | Value |
|---|---|
| compileSdk | 36 |
| targetSdk | 35 |
| Release APK (fat) | ~84.2 MB |
| Release APK (arm64-v8a) | ~31.3 MB |
| Obfuscation | `--obfuscate --split-debug-info=build/debug-info` |

### 8.7 Test Suite (144 tests across 14 files)

| Category | Files | Tests |
|---|---|---|
| Unit | 6 | 36 |
| DAO | 2 | 31 |
| Provider | 2 | 20 |
| Widget | 1 | 4 |
| Integration | 2 | 35 |
| Sync | 1 | 18 |
| **Total** | **14** | **144** |

---

## 9. Admin Dashboard

React 18 + Vite 6 + Supabase JS, deployed on Vercel.

### 9.1 Pages (11)

LoginPage, DashboardPage, PredictionsPage, ModelsPage, UsersPage,
DataManagementPage, ReleasesPage, SystemHealthPage, SettingsPage,
ModelReportsPage, DevicesPage.

### 9.2 Features

- Auth: Admin role check via `is_admin_role()` PostgreSQL function
- OAuth: Google and GitHub sign-in buttons
- Dashboard: 4 stat cards + BarChart (daily scans) + PieChart (disease distribution)
- Predictions: Paginated table + filters + CSV/JSON export
- Models: Model registry with lifecycle management (staging/active/backup)
- Data Management: 5-tab DVC operations (stage/push/pull/export/delete)
- Devices: Fleet management + provisioning token generation
- Security headers: CSP and HSTS in `vercel.json` (production); X-Frame-Options + X-Content-Type-Options in `vite.config.js` (dev)
- Error tracking: `@sentry/react`

### 9.3 Tests (113 tests across 6 files)

| File | Tests |
|---|---|
| App.test.jsx | 3 |
| components.test.jsx | 12 |
| data-context.test.jsx | 12 |
| helpers.test.js | 34 |
| helpers-advanced.test.js | 25 |
| integration.test.jsx | 27 |
| **Total** | **113** |

---

## 10. MLOps Pipeline

### 10.1 Config-Driven Workflow

All scripts accept `--config <path>` pointing to a per-leaf JSON in `mlops_pipeline/configs/`.
The orchestrator `run_pipeline.py` runs the full pipeline for a given config.

### 10.2 Conversion Flows

```
Flow 1: .pth → .onnx (convert_pth_to_onnx.py)
Flow 2: .onnx → .tflite float32 + float16 (convert_onnx_to_tflite.py, via onnx2tf)
Flow 3: .onnx → .engine FP16 (convert_onnx_to_tensorrt.py, Jetson only)
Alt:    .pth → .tflite (convert_pth_to_tflite.py, ai-edge-torch, Linux only)
```

### 10.3 Evaluation & Validation

- `evaluate_models.py`: Top-1 accuracy on test set for all formats
- `validate_models.py`: cross-format accuracy check
- Random seeds set globally (`random`, `numpy`, `torch`) for reproducibility
- `model_metadata.json` emitted after evaluation (SHA-256, accuracy, size)

### 10.4 Known Issues

- `validate_models.py` may show "FAIL" on random noise inputs (fresh model instances with different batch norm stats) — not a real failure
- `convert_pth_to_tflite.py` (ai-edge-torch) only works on Linux
- Windows cp1252 encoding: `run_pipeline.py` has UTF-8 reconfigure fix

### 10.5 Output Structure

```
models/<leaf_type>/
├── <leaf_type>_student.onnx
├── <leaf_type>_student.tflite          # float32
├── <leaf_type>_student_float16.tflite  # float16
├── benchmark_report.md
├── benchmark_chart.png
└── model_metadata.json
```

---

## 11. Database Schema

### 11.1 Mobile SQLite (sqflite)

| Table | Key Columns | Purpose |
|---|---|---|
| `predictions` | id, leaf_type, predicted_class_name, confidence, image_path, timestamp | Diagnosis history |
| `models` | id, leaf_type, version, file_path, sha256, role, is_selected, UNIQUE(leaf_type, version) | OTA model registry (multi-version, max 2 active) |
| `user_preferences` | key, value | Theme, language, default leaf type, etc. |
| `sync_queue` | id, entity_type, entity_id, action, payload, retry_count, max_retries, status, created_at, completed_at | Offline-first sync buffer |

Default preferences seeded on first run: `default_leaf_type=tomato`, `auto_sync=true`, `theme=system`, `save_images=true`, `language=en`.

### 11.2 Jetson SQLite

| Table | Key Columns | Purpose |
|---|---|---|
| `predictions` | id, leaf_type, predicted_class_name, confidence, image_path, timestamp, is_synced, device_id, uploaded_image_url, sync_retry_count | Inference log with sync tracking |

Composite index on `(is_synced, id)` for efficient unsynced-row queries.

### 11.3 Supabase PostgreSQL (13 tables)

| Table | Key Columns | Purpose |
|---|---|---|
| `predictions` | id, user_id, device_type, leaf_type, predicted_class_name, confidence, image_url, created_at | Aggregated predictions from all clients |
| `model_registry` | id, leaf_type, version, status, model_url, pth_url, sha256, UNIQUE(leaf_type, version) | Published model versions for OTA (status: staging/active/backup) |
| `profiles` | id (FK auth.users), display_name, role, created_at | User profile and role management |
| `audit_log` | id, user_id, action, details, created_at | Audit trail for admin actions |
| `model_benchmarks` | id, leaf_type, version, format, accuracy, per_class_metrics | Stored benchmark results per format |
| `model_versions` | id, leaf_type, version, model_url, accuracy, archived_at | Archived model version snapshots |
| `model_reports` | id, user_id, model_version, leaf_type, prediction_id, reason, created_at | User feedback on wrong predictions |
| `pipeline_runs` | id, leaf_type, version, status, github_run_id, triggered_by | CI/CD pipeline tracking (Realtime) |
| `dvc_operations` | id, leaf_type, operation, source, status, metadata, github_run_id, triggered_by | DVC operation tracking with Realtime |
| `provisioning_tokens` | id, created_by, expires_at, used_at, used_by_hw_id, device_id, label | One-time tokens for Zero-Touch Provisioning (24h expiry) |
| `devices` | id, hw_id, hostname, device_name, status, user_id, device_token, desired_config, reported_config, config_version, last_seen_at, hw_info | Jetson device registry with Device Shadow pattern |
| `model_engines` | id, leaf_type, version, hw_tag, engine_url, sha256, created_at | Cached TensorRT engines per hardware type |
| `system_secrets` | key, value, description, updated_at, updated_by | Admin-managed secrets (e.g., GCS key for DVC). Devices read via `get_system_secret` RPC |

### 11.4 RLS Audit (IaC)

`database/verify_rls_policies.sql` checks seven categories:

1. RLS status on all required tables
2. Policies per table
3. `is_admin_role()` function (SECURITY DEFINER)
4. `handle_new_user()` trigger (auth.users → profiles)
5. `enforce_version_lifecycle()` trigger on model_registry
6. Storage bucket policies (models, datasets, prediction-images)
7. Index verification

---

## 12. CI/CD

### 12.1 Workflows Overview (13 workflows)

| Workflow | File | Trigger | Purpose |
|---|---|---|---|
| CI | `ci.yml` | Push/PR to `main`/`develop` | Lint, test, build APK, dashboard tests, Jetson lint |
| Release | `release.yml` | Tag `v*` | Build release APK + GitHub Release |
| CodeQL | `codeql.yml` | Push/PR to `main`, weekly | SAST security scanning (JS/TS, Python) |
| Model Pipeline | `model-pipeline.yml` | Manual | Full convert + validate + upload |
| Deploy | `deploy.yml` | Manual | Vercel deploy for admin dashboard |
| Train | `train.yml` | Manual | Run model training |
| Validate Model | `validate-model.yml` | Manual | Cross-format validation only |
| DVC Pull | `dvc-pull.yml` | Manual | Pull dataset files from GCS via DVC |
| DVC Push | `dvc-push.yml` | Manual | Push dataset files to GCS via DVC |
| Export Data | `export-data.yml` | Manual | Export prediction records |
| Dataset Upload | `dataset-upload.yml` | Manual | Upload datasets to DVC (GCS) |
| Dataset Delete | `dataset-delete.yml` | Manual | Delete dataset from DVC + GCS cleanup |
| Model Rollback | `model-rollback.yml` | Manual | Rollback model version in registry |

**Automatic:** ci.yml, codeql.yml, release.yml (3).
**Manual:** All others (10).

### 12.2 CI Pipeline Jobs (6 jobs)

| Job | Details |
|---|---|
| `audit` | Security audit (npm audit, pip audit) |
| `lint` | `dart format --set-exit-if-changed` + `flutter analyze` |
| `test` | `flutter test --exclude-tags=widget` (140 tests) |
| `build` | `flutter build apk --release` with `--obfuscate` |
| `dashboard-test` | `npm test` (113 admin dashboard tests) |
| `jetson-lint` | `ruff check jetson/app/ jetson/scripts/` |

### 12.3 Required Secrets (13 + 1 auto)

| Secret | Used By | Purpose |
|---|---|---|
| `SUPABASE_URL` | ci, release, model-pipeline, model-rollback, export-data, dataset-upload, dataset-delete, deploy, dvc-pull, dvc-push | Supabase project URL |
| `SUPABASE_ANON_KEY` | ci, release | Supabase anonymous key |
| `SUPABASE_SERVICE_ROLE_KEY` | model-pipeline, model-rollback, export-data, dataset-upload, dataset-delete, dvc-pull, dvc-push | Service role key (bypasses RLS) |
| `SENTRY_DSN` | ci, release | Sentry DSN |
| `GOOGLE_WEB_CLIENT_ID` | ci, release | Google OAuth client ID |
| `GOOGLE_APPLICATION_CREDENTIALS_DATA` | train, validate-model, model-pipeline, dvc-pull, dvc-push, export-data, dataset-upload, dataset-delete | GCS service account JSON for DVC |
| `VERCEL_DEPLOY_HOOK` | deploy | Vercel deploy webhook URL |
| `KAGGLE_USERNAME` | dataset-upload | Kaggle API username |
| `KAGGLE_KEY` | dataset-upload | Kaggle API key |
| `KEYSTORE_BASE64` | release | Base64-encoded release keystore |
| `KEYSTORE_PASSWORD` | release | Keystore password |
| `KEY_PASSWORD` | release | Key password |
| `KEY_ALIAS` | release | Key alias |
| `GITHUB_TOKEN` | release | Auto-provided by GitHub Actions |

### 12.4 Build Command

```bash
flutter build apk --release \
  --obfuscate \
  --split-debug-info=build/debug-info \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=GOOGLE_WEB_CLIENT_ID=$GOOGLE_WEB_CLIENT_ID
```

---

## 13. Security

### 13.1 Flutter App

- Dart code obfuscation in release builds
- SHA-256 model integrity verification + magic bytes validation
- Image format validation (JPEG/PNG header check)
- Path sanitization against path traversal
- Sentry error tracking (`sentry_flutter`)
- No hardcoded credentials (`.env` for dev, `--dart-define` for CI)

### 13.2 Admin Dashboard

- Security headers: CSP, X-Frame-Options, X-Content-Type-Options, HSTS, Referrer-Policy
- Sentry error tracking (`@sentry/react`)
- Admin role enforcement via `is_admin_role()` PostgreSQL function

### 13.3 Jetson

- Rate limiting: 30 req/min per IP
- Upload size limit: 10 MB
- MIME validation on file uploads
- API key authentication (`X-API-Key` header)
- TLS termination via Nginx reverse proxy (production)

### 13.4 Supabase

- Row-Level Security (RLS) on all tables
- `is_admin_role()` SECURITY DEFINER function
- Storage bucket policies (user-scoped uploads)
- PKCE auth flow

### 13.5 CI/CD

- Workflow inputs passed via env vars (prevent expression injection)
- CodeQL SAST scanning on every push/PR to main
- No `continue-on-error` on validation steps (hard gate)
- Debug symbols uploaded as artifacts (not in APK)

---

## 14. Environment Variables

### 14.1 Required Variables

| Variable | Description | Used By |
|---|---|---|
| `SUPABASE_URL` | Supabase project URL | Flutter, Admin, Jetson, CI |
| `SUPABASE_ANON_KEY` | Supabase anonymous key | Flutter, Admin, Jetson, CI |
| `GOOGLE_WEB_CLIENT_ID` | Google OAuth client ID | Flutter |
| `SUPABASE_SERVICE_ROLE_KEY` | Service-level access (bypasses RLS) | CI workflows |
| `SENTRY_DSN` | Sentry error tracking DSN | Flutter, Admin |
| `GOOGLE_APPLICATION_CREDENTIALS_DATA` | GCS service account JSON | DVC workflows |
| `VERCEL_DEPLOY_HOOK` | Vercel deploy webhook URL | deploy.yml |
| `KAGGLE_USERNAME` | Kaggle API username | dataset-upload.yml |
| `KAGGLE_KEY` | Kaggle API key | dataset-upload.yml |

### 14.2 Sensitive Files

| Path | Status | If Exposed |
|---|---|---|
| `.dvc/gcs-sa.json` | Gitignored | Rotate GCS SA key |
| `jetson/config/config.json` | Gitignored | Recreate from config.example.json |
| `.env` | Gitignored | Rotate all keys |

---

## 15. Production Deploy Checklist

1. **Supabase Dashboard**: Set Site URL + Redirect URLs → `com.agrikd.app://callback`
2. **Google OAuth**: Create OAuth 2.0 Client ID → set `GOOGLE_WEB_CLIENT_ID`
3. **GitHub Secrets**: Configure all 13 secrets listed in Section 12.3
4. **DVC**: Google Drive folder ID in `.dvc/config` (already configured)
5. **Migrations**: Run 001-023 in order in Supabase SQL Editor
6. **Realtime**: Automated in migration 011 (falls back to manual)
7. **Release**: APK distributed via GitHub Releases (no Play Store)
