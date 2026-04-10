# AgriKD -- Architecture & Project Context (Phase 2)

## 1. Project Overview

**AgriKD** (Agricultural Knowledge Distillation) is a plant leaf disease recognition
system built on Knowledge Distillation. A large Vision Transformer (ViT-Base) serves as
the teacher model, and a truncated MobileNetV2 serves as the student model. The student
is optimized for real-time inference on resource-constrained devices -- mobile phones and
NVIDIA Jetson edge hardware -- while retaining accuracy competitive with the teacher.

| Property | Value |
|---|---|
| Distillation pair | ViT-Base (teacher) -> Truncated MobileNetV2 (student) |
| Tomato dataset | 10 disease/healthy classes |
| Burmese Grape Leaf dataset | 5 disease/healthy classes |
| Design philosophy | Zero-cost infrastructure, offline-first operation |

The system spans four deployment targets: a Flutter mobile application (located in
`mobile_app/`), a Supabase cloud backend, a React admin dashboard, and a Jetson edge
inference station. All model artifacts are produced by a single MLOps pipeline and
versioned with DVC.

Phase 2 introduced production hardening across all targets: Sentry error tracking in
both the Flutter app and the admin dashboard, Dart code obfuscation in release builds,
rate-limited and MIME-validated Jetson API endpoints, security headers on the admin
dashboard, and an Infrastructure-as-Code RLS audit script for the Supabase database.

Phase 3 (production audit round 2) applied targeted fixes across all components:
- **Flutter**: corrected `StateNotifier.mounted` usage in `AuthNotifier`; added RGBA→RGB
  and grayscale→RGB channel normalisation in `ImagePreprocessor` using `image.convert()`;
  bumped Android `targetSdk` to 35.
- **MLOps pipeline**: replaced bulk `np.vstack` preload with lazy per-sample access to
  eliminate OOM risk on large datasets; added `model_metadata.json` emission (SHA-256
  checksums, accuracy, size) after each evaluation run; set global random seeds
  (`random`, `numpy`, `torch`) in `evaluate_models.py` and `validate_models.py` for
  reproducible results; removed `continue-on-error: true` from the CI cross-format
  validation step to make it a hard gate.
- **Admin Dashboard**: added Google and GitHub OAuth sign-in buttons to `LoginPage.jsx`
  via `supabase.auth.signInWithOAuth()`.
- **Jetson**: added sync-thread liveness check in the main loop with automatic restart;
  added composite `(is_synced, id)` index on the SQLite predictions table for efficient
  unsynced-row queries.

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
| Mobile Framework | Flutter + Dart | 3.41.4 |
| State Management | Riverpod (flutter_riverpod) | 2.6.1 |
| ML Inference (Mobile) | tflite_flutter | 0.12.1 |
| Error Tracking (Mobile) | sentry_flutter | ^9.0.0 |
| ML Inference (Edge) | TensorRT FP16 | JetPack r8.5.2 |
| Edge GUI | PyQt5 | System package |
| Edge REST API | Flask | Rate-limited (30 req/min), 10 MB upload limit |
| Backend | Supabase (PostgreSQL + Auth + Storage) | Managed |
| Admin Dashboard | React 18 + Vite 5 | SPA on Vercel |
| Error Tracking (Dashboard) | @sentry/react | ^10.47.0 |
| MLOps Runtime | Python 3.10 + DVC + GitHub Actions | venv at venv_mlops/ |
| Edge Hardware | NVIDIA Jetson (ARM64) | L4T-based |
| Local Database | SQLite (sqflite 2.4.1 / Python sqlite3) | - |
| Authentication | Supabase Auth + Google Sign-In 6.2.1 | PKCE flow |
| IaC Audit | PL/pgSQL (verify_rls_policies.sql) | Run in SQL Editor |

---

## 4. Repository Structure

```
agrikd/
├── mobile_app/                        # Flutter app (Clean Architecture + Riverpod)
│   ├── lib/
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
│   │   └── providers/                 # Riverpod providers (auth, diagnosis, inference, benchmark, model_version, ...)
│   ├── assets/models/                 # Bundled TFLite models (~0.96 MB each)
│   ├── android/                       # Android platform files
│   ├── ios/                           # iOS platform files
│   ├── linux/                         # Linux desktop platform files
│   ├── macos/                         # macOS desktop platform files
│   ├── windows/                       # Windows desktop platform files
│   ├── web/                           # Web platform files
│   ├── test/                          # Unit, widget, and provider tests
│   ├── pubspec.yaml                   # Flutter dependencies (includes sentry_flutter)
│   └── .env                           # Local dev env (copied by sync_env.py)
│
├── admin-dashboard/                   # React + Vite admin panel
│   └── src/
│       ├── pages/                     # Dashboard, Users, Models, Predictions,
│       │                              #   Releases, DataManagement, SystemHealth,
│       │                              #   Settings, ModelReports, Devices, Login
│       ├── components/                # Layout, ConfirmDialog, CustomTooltip, ErrorBoundary
│       └── lib/                       # Supabase client, helpers
│   ├── vite.config.js                 # Security headers (X-Frame-Options, etc.)
│   └── package.json                   # Includes @sentry/react
│
├── jetson/                            # Edge inference station
│   ├── app/                           # main.py, gui_app.py, inference.py, camera.py,
│   │                                  #   database.py, sync_engine.py, health_server.py
│   ├── scripts/
│   │   └── provision.py               # Zero-Touch Provisioning CLI
│   ├── config/
│   │   ├── config.example.json        # Template (committed); fill and rename to config.json
│   │   └── config.json                # Runtime config (gitignored, never committed)
│   ├── Dockerfile                     # L4T-based container
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
│   ├── migrations/
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
│   │   ├── 012_devices.sql            # Device management: provisioning_tokens, devices, RLS, Device Shadow
│   │   ├── 013_model_engines.sql      # Model engines table (TensorRT), ONNX URL support, engine RPCs
│   │   ├── 014_audit_fixes.sql        # Admin guards on dashboard RPCs, profile/report policies
│   │   └── 015_audit_log_cleanup.sql  # audit_log schema normalization (UUID, user_id)
│   ├── verify_all_migrations.sql      # Comprehensive verify for all 15 migrations
│   └── verify_rls_policies.sql        # RLS audit: tables, policies, triggers, storage, indexes
│
├── .github/workflows/                 # CI/CD (12 workflow files)
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
│   └── dataset-upload.yml             # Upload datasets to storage (staging + DVC)
├── .github/scripts/
│   └── stage_dataset_to_storage.py    # Stage dataset ZIP to Supabase Storage
│
├── docs/                              # Project documentation
├── data/                              # DVC-tracked datasets (gitignored)
├── model_checkpoints_student/         # KD-trained .pth checkpoints (gitignored)
├── models/                            # Converted ONNX + TFLite outputs (gitignored)
├── sync_env.py                        # Centralized .env sync (root -> mobile_app, admin, jetson)
├── setup_windows_dev.bat              # Windows dev environment setup
└── .env.example                       # Environment variable template (includes SENTRY_DSN)
```

---

## 5. Data Flow

### 5.1 Training Pipeline

```
Raw Images (DVC)
    |
    v
ViT-Base Teacher (pretrained)
    |  Knowledge Distillation (KL Divergence + CE Loss)
    v
MobileNetV2 Student (.pth checkpoint)
```

Training is performed externally and produces a `.pth` checkpoint containing the
`student_state_dict`. Class indices follow the alphabetical order of dataset folder
names (PyTorch ImageFolder convention).

### 5.2 Model Conversion Pipeline

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
    +--> validate_models.py  (KL Divergence cross-format check)
    +--> evaluate_models.py  (Top-1 accuracy on test set)
```

All scripts accept a `--config` flag pointing to a per-leaf JSON configuration file.

### 5.3 Mobile Inference (Flutter)

```
Camera / Gallery Image
    |
    v
Resize to 224x224 + ImageNet normalization
    mean = [0.485, 0.456, 0.406]
    std  = [0.229, 0.224, 0.225]
    |
    v
TFLite Interpreter (GPU -> XNNPack -> CPU delegate fallback)
    |
    v
Softmax over logits -> class probabilities
    |
    v
Result Screen (top prediction + probability bar chart)
    |
    v
SQLite (predictions table) --> SyncQueue --> Supabase REST
    |
    v
Sentry (sentry_flutter) captures unhandled exceptions and performance traces
```

Inference runs inside a Dart `compute()` isolate to keep the UI thread responsive.
The Flutter project lives under `mobile_app/` and reads its `.env` from that directory
(copied from the root `.env` by `sync_env.py`, since Flutter asset references cannot
reach parent directories).

### 5.4 Jetson Edge Inference

```
USB Camera / Image File
    |
    v
InferenceWorkerPool (TensorRT FP16, dedicated CUDA thread)
    |
    v
PyQt5 GUI display + SQLite logging (threading.Lock)  ← LOCAL-FIRST (never blocked by network)
    |
    v
SyncEngine --> Supabase REST (when online, best-effort push, graceful shutdown)
    |
    v
Device Config Poll --> Device Shadow (desired_config / reported_config)
```

The Jetson edge device follows a **Local-First, Cloud-Sync** architecture:
- Capture, inference, and SQLite save run on the main thread with **zero network dependency**.
- **InferenceWorkerPool**: A single worker thread owns the CUDA context and all TensorRT buffers. All callers submit jobs via `queue.Queue`, receive results via `concurrent.futures.Future`. This eliminates CUDA context-affinity and shared-buffer race conditions.
- **SQLite thread-safety**: A single `threading.Lock` serializes all DB operations on the shared connection.
- **Wake-Capture-Sleep**: In periodic mode, camera opens/captures/releases per cycle to reduce heat and sensor wear.
- The `SyncEngine` daemon thread handles cloud sync, device config polling, and heartbeats.
- If no user is assigned (`user_id = NULL`), predictions queue in SQLite. On assignment, the full backlog is synced.
- **Device Shadow**: Admin sets `desired_config` (mode, interval, leaf type) via the dashboard. The Jetson polls for config changes, applies them, and reports `reported_config` as acknowledgement. `config_version` auto-increments on each change.
- **Zero-Touch Provisioning**: A single `agrikd://` token (generated by Admin) configures Supabase credentials, registers hardware identity (`hw_id = SHA-256(MAC:serial)`), and starts services automatically.

The Jetson Flask API (`health_server.py`) enforces the following hardening measures:

- **Rate limiting**: 30 requests per minute per IP on all endpoints (in-memory sliding window).
- **Upload size limit**: 10 MB maximum (`MAX_CONTENT_LENGTH`).
- **MIME validation**: Only `jpg`, `jpeg`, `png`, `bmp`, `tiff` extensions accepted.
- **API key authentication**: Optional `X-API-Key` header validated against `server.api_key` in config.
- **Error handler**: Returns structured JSON for 413 (entity too large) responses.

Runtime configuration is loaded from `jetson/config/config.json`, which is gitignored.
Developers copy `config.example.json` and fill in their credentials locally.

### 5.5 Synchronization

Both the Flutter app and the Jetson device maintain a local queue of unsynchronized
prediction records. When network connectivity is detected, the queue is flushed to
Supabase via its REST API. Conflict resolution uses a last-write-wins strategy with
server-side timestamps.

### 5.6 Environment Variable Distribution

The root `.env` file is the single source of truth. Running `python sync_env.py`
distributes credentials to three sub-projects:

| Target | Output Path | Notes |
|---|---|---|
| Flutter app | `mobile_app/.env` | Direct copy (Flutter assets cannot reference parent dirs) |
| Admin dashboard | `admin-dashboard/.env` | Re-prefixed as `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SENTRY_DSN` |
| Jetson config | `jetson/config/config.json` | Injects `supabase_url` and `supabase_key` into the `sync` block |

In CI, Flutter builds receive secrets via `--dart-define` flags instead of `.env` files.

---

## 6. Model Architecture

### Student Network

| Component | Detail |
|---|---|
| Backbone | MobileNetV2 `features[0:12]` (truncated from 19 blocks) |
| Backbone output | 96 channels |
| Pooling | Adaptive Average Pooling -> [batch, 96] |
| Classifier | `96 -> 512 -> ReLU -> Dropout(0.3) -> 256 -> ReLU -> Dropout(0.3) -> N` |
| Input | 224 x 224 x 3, ImageNet normalization |
| Output | Raw logits [batch, N] (softmax applied at inference time) |

### Benchmark Results

| Dataset | Top-1 Accuracy | KL Div (PyTorch/ONNX) | KL Div (TFLite) | TFLite Size |
|---|---|---|---|---|
| Tomato (10 classes) | 87.2% | 0.000000 | 0.000011 | ~0.96 MB |
| Burmese Grape Leaf (5 classes) | 87.3% | 0.000000 | 0.000002 | ~0.96 MB |

KL Divergence is measured between the PyTorch reference output and each exported
format to verify numerical fidelity across the conversion pipeline.

---

## 7. CI/CD Workflow Map

All 11 workflows live in `.github/workflows/`. Flutter-related jobs use
`working-directory: mobile_app` since the Flutter project was relocated from the
repository root to the `mobile_app/` subdirectory.

Release and CI builds apply Dart code obfuscation (`--obfuscate`) and split debug
information (`--split-debug-info=build/debug-info`). Debug symbol archives are uploaded
as GitHub Actions artifacts (30-day retention for CI, 365-day for tagged releases).

The `SENTRY_DSN` secret is injected at build time via `--dart-define=SENTRY_DSN=...`
alongside `SUPABASE_URL` and `SUPABASE_ANON_KEY`.

| Workflow | File | Trigger | Purpose | Notes |
|---|---|---|---|---|
| CI | `ci.yml` | Push / PR to `main` | Lint, test, model conversion, build APK | `working-directory: mobile_app`; `--obfuscate`; uploads debug symbols |
| Release | `release.yml` | Tag `v*` | Build release APK + GitHub Release | `working-directory: mobile_app`; `--obfuscate`; debug symbols retained 365 days |
| Model Pipeline | `model-pipeline.yml` | Manual | Full convert + validate + upload cycle | Runs both tomato and burmese configs |
| Deploy | `deploy.yml` | Manual | Vercel deploy for admin dashboard | - |
| Train | `train.yml` | Manual | Run model training | - |
| Validate Model | `validate-model.yml` | Manual | Cross-format validation only | - |
| DVC Pull | `dvc-pull.yml` | Manual | Pull dataset files from DVC remote | - |
| DVC Push | `dvc-push.yml` | Manual | Push dataset files to DVC remote | - |
| Export Data | `export-data.yml` | Manual | Export prediction records | - |
| Dataset Upload | `dataset-upload.yml` | Manual | Upload datasets to storage | - |
| Model Rollback | `model-rollback.yml` | Manual | Rollback model version in registry | Requires `SUPABASE_SERVICE_ROLE_KEY` |

### Required CI Secrets

Nine secrets must be configured in the GitHub repository settings across all
workflows (the `GITHUB_TOKEN` is auto-provided and not counted):

| Secret | Used By | Purpose |
|---|---|---|
| `SUPABASE_URL` | ci.yml, release.yml, model-pipeline.yml, model-rollback.yml, export-data.yml, dataset-upload.yml | Supabase project URL |
| `SUPABASE_ANON_KEY` | ci.yml, release.yml | Supabase anonymous key for `--dart-define` |
| `SUPABASE_SERVICE_ROLE_KEY` | model-pipeline.yml, model-rollback.yml, export-data.yml, dataset-upload.yml | Service role key (bypasses RLS) |
| `SENTRY_DSN` | ci.yml, release.yml | Sentry Data Source Name for error tracking |
| `GOOGLE_WEB_CLIENT_ID` | ci.yml, release.yml | Google OAuth client ID for `--dart-define` |
| `GOOGLE_APPLICATION_CREDENTIALS_DATA` | train.yml, validate-model.yml, model-pipeline.yml, dvc-pull.yml, dvc-push.yml, export-data.yml, dataset-upload.yml | GCS service account JSON for DVC |
| `VERCEL_DEPLOY_HOOK` | deploy.yml | Vercel deploy webhook URL |
| `KAGGLE_USERNAME` | dataset-upload.yml | Kaggle API username for external dataset downloads |
| `KAGGLE_KEY` | dataset-upload.yml | Kaggle API key for external dataset downloads |
| `GITHUB_TOKEN` | release.yml | Auto-provided; used by `softprops/action-gh-release` |

### Build Command (CI and Release)

```bash
flutter build apk --release \
  --obfuscate \
  --split-debug-info=build/debug-info \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=GOOGLE_WEB_CLIENT_ID=$GOOGLE_WEB_CLIENT_ID
```

The `.env` line is stripped from `pubspec.yaml` assets before the release build to
prevent key leakage in published APKs.

---

## 8. Database Schema

### 8.1 Mobile (SQLite -- sqflite)

| Table | Key Columns | Purpose |
|---|---|---|
| `predictions` | id, leaf_type, predicted_class, confidence, image_path, timestamp | Diagnosis history |
| `models` | id, leaf_type, version, file_path, sha256, role, is_selected, UNIQUE(leaf_type, version) | OTA model registry (multi-version, max 2 active) |
| `user_preferences` | key, value | Theme, language, default leaf type |
| `sync_queue` | id, table_name, record_id, action, synced | Offline-first sync buffer |

### 8.2 Jetson Edge (SQLite)

| Table | Key Columns | Purpose |
|---|---|---|
| `predictions` | id, leaf_type, predicted_class, confidence, image_path, timestamp, is_synced | Inference log with sync flag |

### 8.3 Supabase (PostgreSQL)

| Table | Key Columns | Purpose |
|---|---|---|
| `predictions` | id, user_id, device_type, leaf_type, predicted_class, confidence, image_url, created_at | Aggregated predictions from all clients |
| `model_registry` | id, leaf_type, version, status, model_url, pth_url, sha256, UNIQUE(leaf_type, version) | Published model versions for OTA (status: staging/active/backup) |
| `profiles` | id (FK auth.users), display_name, role, created_at | User profile and role management |
| `audit_log` | id, user_id, action, details, created_at | Audit trail for administrative actions |
| `model_benchmarks` | id, leaf_type, version, format, accuracy, per_class_metrics | Stored benchmark results per format |
| `model_versions` | id, leaf_type, version, model_url, accuracy, archived_at | Archived model version snapshots |
| `model_reports` | id, user_id, model_version, leaf_type, prediction_id, reason, created_at | User feedback on wrong predictions |
| `pipeline_runs` | id, leaf_type, version, status, github_run_id, triggered_by | CI/CD pipeline progress tracking (Realtime) |
| `dvc_operations` | id, leaf_type, operation, source, status, metadata, github_run_id, triggered_by | DVC operation tracking: stage/push/pull/export with Realtime status updates |
| `provisioning_tokens` | id, created_by, expires_at, used_at, used_by_hw_id, device_id, label | One-time tokens for Zero-Touch Provisioning (24h expiry) |
| `devices` | id, hw_id, hostname, device_name, status, user_id, device_token, desired_config, reported_config, config_version, last_seen_at, hw_info | Jetson device registry with Device Shadow pattern |

Row-Level Security (RLS) policies ensure that regular users can only access their own
prediction records, while admin-role users have full read access through the dashboard.
Admin detection uses the `is_admin_role()` PostgreSQL function (defined as
`SECURITY DEFINER`) which checks the user's role in the `profiles` table.

### 8.4 RLS Audit (IaC)

The file `database/verify_rls_policies.sql` is an Infrastructure-as-Code audit script
that can be run in the Supabase SQL Editor to verify the security posture of the
database. It checks seven categories:

1. **RLS status** -- Confirms RLS is enabled on all required tables.
2. **Policies per table** -- Lists and counts all RLS policies.
3. **is_admin_role() function** -- Verifies existence and `SECURITY DEFINER` attribute.
4. **handle_new_user() trigger** -- Ensures new auth.users rows create profile records.
5. **enforce_version_lifecycle() trigger** -- Verifies BEFORE INSERT/UPDATE trigger on model_registry (replaces old sync_model_urls); enforces max 2 active versions per leaf_type.
6. **Storage bucket policies** -- Checks buckets (models, datasets, prediction-images) and their object policies.
7. **Index verification** -- Confirms critical indexes exist for query performance.

The script outputs a PASS/FAIL summary. It is intended to be run manually after any
schema migration to catch regressions.

---

## 9. Class Mappings

### Tomato (10 classes)

| Index | Class Name | Dataset Folder |
|---|---|---|
| 0 | Bacterial Spot | `Tomato___Bacterial_spot` |
| 1 | Early Blight | `Tomato___Early_blight` |
| 2 | Late Blight | `Tomato___Late_blight` |
| 3 | Leaf Mold | `Tomato___Leaf_Mold` |
| 4 | Septoria Leaf Spot | `Tomato___Septoria_leaf_spot` |
| 5 | Spider Mites | `Tomato___Spider_mites Two-spotted_spider_mite` |
| 6 | Target Spot | `Tomato___Target_Spot` |
| 7 | Yellow Leaf Curl Virus | `Tomato___Tomato_Yellow_Leaf_Curl_Virus` |
| 8 | Mosaic Virus | `Tomato___Tomato_mosaic_virus` |
| 9 | Healthy | `Tomato___healthy` |

### Burmese Grape Leaf (5 classes)

| Index | Class Name | Dataset Folder |
|---|---|---|
| 0 | Anthracnose (Brown Spot) | `Anthracnose (Brown Spot)` |
| 1 | Healthy | `Healthy` |
| 2 | Insect Damage | `Insect Damage` |
| 3 | Leaf Spot (Yellow) | `Leaf Spot (Yellow)` |
| 4 | Powdery Mildew | `Powdery Mildew` |

Class indices are determined by alphabetical sort of folder names, following the
PyTorch `ImageFolder` convention. Both the MLOps pipeline config files and the
Jetson `config.example.json` encode these labels in the same order.
