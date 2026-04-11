# AgriKD - Plant Leaf Disease Recognition System
# He thong nhan dien benh tren la cay

---

## 1. Tong quan du an (Project Overview)

**AgriKD** su dung ky thuat **Knowledge Distillation (KD)** de nen tri thuc tu mo hinh lon sang mo hinh cuc nhe, cho phep chay truc tiep tren thiet bi Edge va Mobile ma khong can server.

| Thanh phan | Chi tiet |
|---|---|
| Teacher Model | ViT-Base (Vision Transformer) |
| Student Model | Truncated MobileNetV2 (features[0:12], 96d) |
| Ky thuat | Knowledge Distillation |
| Datasets | Tomato (10 classes), Burmese Grape Leaf (5 classes) |
| Chi phi | Zero-cost (100% open-source, free-tier services) |
| Tinh chat | Offline-First, auto-sync khi co mang |

**Mo hinh theo kieu Model-per-leaf**: Moi loai la cay co mot checkpoint (.pth) rieng, duoc train rieng biet tren bo du lieu tuong ung.

---

## 2. Kien truc Student Model (Model Architecture)

### 2.1 Backbone
- **MobileNetV2** truncated: chi lay `features[0:12]`
- Output channels: **96**
- Pre-trained ImageNet backbone, fine-tuned qua KD

### 2.2 Classifier Head
```
AdaptiveAvgPool2d(1)  ->  Flatten
Linear(96, 512)       ->  ReLU  ->  Dropout(0.3)
Linear(512, 256)      ->  ReLU  ->  Dropout(0.3)
Linear(256, N)        # N = so class cua tung loai la
```

### 2.3 Input Specification
| Thuoc tinh | Gia tri |
|---|---|
| Input size | 224 x 224 |
| Channels | 3 (RGB) |
| Normalize mean | [0.485, 0.456, 0.406] |
| Normalize std | [0.229, 0.224, 0.225] |
| Format (PyTorch/ONNX) | NCHW |
| Format (TFLite) | NHWC (onnx2tf auto-convert) |

### 2.4 Pre-processing Pipeline (PyTorch reference)
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
> **Luu y**: Flutter app phai replicate chinh xac pipeline nay. `ToTensor()` chia cho 255.0 va chuyen HWC->CHW. TFLite input la NHWC nen khong can chuyen axis, chi can normalize.

### 2.5 Class Mapping (ImageFolder Alphabetical Sort)

**QUAN TRONG**: PyTorch `ImageFolder` gan class index theo `sorted(os.listdir())` tren folder names. Thu tu nay **khong phai** thu tu logic ma la thu tu alphabet.

#### Tomato (10 classes)
| Index | Folder Name | Tieng Viet |
|---|---|---|
| 0 | Tomato___Bacterial_spot | Dom vi khuan |
| 1 | Tomato___Early_blight | Suong mai som |
| 2 | Tomato___Late_blight | Suong mai muon |
| 3 | Tomato___Leaf_Mold | Moc la |
| 4 | Tomato___Septoria_leaf_spot | Dom la Septoria |
| 5 | Tomato___Spider_mites Two-spotted_spider_mite | Nhen do hai cham |
| 6 | Tomato___Target_Spot | Dom dich |
| 7 | Tomato___Tomato_Yellow_Leaf_Curl_Virus | Virus xoan vang la |
| 8 | Tomato___Tomato_mosaic_virus | Virus kham |
| 9 | Tomato___healthy | Khoe manh |

#### Burmese Grape Leaf (5 classes)
| Index | Folder Name | Tieng Viet |
|---|---|---|
| 0 | Anthracnose (Brown Spot) | Than thu - Dom nau |
| 1 | Healthy | Khoe manh |
| 2 | Insect Damage | Hu hai do con trung |
| 3 | Leaf Spot (Yellow) | Dom vang la |
| 4 | Powdery Mildew | Phan trang |

> Cac class mapping nay duoc luu trong `mlops_pipeline/configs/<leaf_type>.json` cung voi full metadata.

---

## 3. Cau truc thu muc (Directory Structure)

```
app/
|-- lib/                              # Flutter app source (53 files)
|   |-- main.dart                     # Entry point, ProviderScope, initialization
|   |-- core/
|   |   |-- config/
|   |   |   |-- supabase_config.dart  # Supabase client + PKCE auth flow
|   |   |-- constants/
|   |   |   |-- app_constants.dart    # Image size, ImageNet normalization, sync batch
|   |   |   |-- model_constants.dart  # LeafModelInfo, class labels, bilingual names
|   |   |-- l10n/
|   |   |   |-- app_strings.dart      # Lightweight i18n (EN + VI, ~300 keys each)
|   |   |-- theme/
|   |   |   |-- app_theme.dart        # Material 3, green seed, light/dark
|   |   |-- utils/
|   |       |-- file_helper.dart      # Conditional export (stub/mobile)
|   |       |-- image_compressor.dart # Image compression (top-level for isolate)
|   |       |-- image_preprocessor.dart # 224x224 + ImageNet norm (isolate-capable)
|   |       |-- image_widget.dart     # Conditional export (stub/mobile)
|   |       |-- model_integrity.dart  # SHA-256 checksum verification
|   |-- data/
|   |   |-- database/
|   |   |   |-- app_database.dart     # SQLite singleton, 4 tables, web/test support
|   |   |   |-- dao/
|   |   |       |-- model_dao.dart    # CRUD models table
|   |   |       |-- prediction_dao.dart # CRUD predictions, statistics queries
|   |   |       |-- preference_dao.dart # Key-value preferences
|   |   |-- sync/
|   |       |-- sync_queue.dart       # Offline-first queue (pending/retry)
|   |       |-- supabase_sync_service.dart # Push predictions, model OTA check
|   |-- features/
|   |   |-- auth/
|   |   |   |-- presentation/screens/
|   |   |       |-- login_screen.dart          # Email + Google Sign-In
|   |   |       |-- register_screen.dart       # Email signup + confirmation dialog
|   |   |       |-- forgot_password_screen.dart # Request reset email
|   |   |       |-- reset_password_screen.dart  # Set new password (deep link)
|   |   |-- diagnosis/
|   |   |   |-- domain/models/prediction.dart
|   |   |   |-- domain/repositories/diagnosis_repository.dart
|   |   |   |-- data/
|   |   |   |   |-- diagnosis_repository_impl.dart  # Load, preprocess, infer, save
|   |   |   |   |-- tflite_inference_service.dart    # Conditional export
|   |   |   |   |-- tflite_inference_service_mobile.dart  # GPU/XNNPack/CPU fallback
|   |   |   |-- presentation/screens/
|   |   |   |   |-- home_screen.dart      # Bottom nav, leaf selector, IndexedStack
|   |   |   |   |-- camera_screen.dart    # Conditional export (stub/mobile)
|   |   |   |   |-- result_screen.dart    # Diagnosis result, fl_chart, notes
|   |   |   |-- presentation/widgets/
|   |   |       |-- stats_card.dart       # Home stats summary
|   |   |-- history/
|   |   |   |-- presentation/screens/
|   |   |       |-- history_screen.dart   # Paginated list, search, filters
|   |   |       |-- detail_screen.dart    # Full prediction detail
|   |   |       |-- stats_screen.dart     # Bar chart + pie chart statistics
|   |   |-- settings/
|   |       |-- presentation/screens/
|   |           |-- settings_screen.dart  # Account, sync status, theme, language
|   |           |-- benchmark_screen.dart # On-device TFLite benchmark
|   |-- providers/
|       |-- auth_provider.dart         # AuthNotifier, AuthStatus (incl. passwordRecovery)
|       |-- benchmark_provider.dart    # Remote model benchmark metrics from Supabase
|       |-- connectivity_provider.dart # Stream-based online/offline detection
|       |-- database_provider.dart     # DAO providers
|       |-- diagnosis_provider.dart    # DiagnosisNotifier, selectedLeafType
|       |-- history_provider.dart      # Paginated load, filters, search, sort
|       |-- inference_provider.dart    # TfliteInferenceService singleton
|       |-- model_version_provider.dart # Multi-version model state (select, list)
|       |-- settings_provider.dart     # Key-value settings, themeModeProvider
|       |-- sync_provider.dart         # Auto-sync, model updates, sync status
|
|-- mlops_pipeline/                   # Python ML pipeline
|   |-- configs/
|   |   |-- tomato.json               # Config cho Tomato (10 classes)
|   |   |-- burmese_grape_leaf.json   # Config cho Burmese (5 classes)
|   |   |-- model_registry.json       # Central model index
|   |-- scripts/
|   |   |-- model_definition.py       # Model architecture + config loader
|   |   |-- convert_pth_to_onnx.py    # PTH -> ONNX
|   |   |-- convert_onnx_to_tflite.py # ONNX -> TFLite (onnx2tf)
|   |   |-- convert_pth_to_tflite.py  # PTH -> TFLite (direct, Linux only)
|   |   |-- convert_onnx_to_tensorrt.py # ONNX -> TensorRT (Jetson only)
|   |   |-- validate_models.py        # Cross-format output validation
|   |   |-- evaluate_models.py        # Full benchmark + reports
|   |   |-- run_pipeline.py           # Pipeline orchestrator
|   |-- requirements.txt
|
|-- model_checkpoints_student/        # Raw .pth checkpoints (tu KD training)
|   |-- tomato_student.pth            # ~2.0 MB
|   |-- burmese_grape_leaf_student.pth # ~2.0 MB
|
|-- models/                           # Converted models + benchmark reports
|   |-- tomato/                       # .onnx, .tflite, benchmark_report.md, charts
|   |-- burmese_grape_leaf/           # .onnx, .tflite, benchmark_report.md, charts
|
|-- data/                             # Datasets (git-ignored, DVC-tracked)
|   |-- tomato/                       # 10 class folders, ImageFolder format
|   |-- burmese_grape_leaf/           # 5 class folders, ImageFolder format
|
|-- admin-dashboard/                  # React admin dashboard
|   |-- src/
|   |   |-- pages/                    # 10 pages (Login, Dashboard, Predictions, Models, Users, DataManagement, Releases, SystemHealth, ModelReports, Settings)
|   |   |-- components/Layout.jsx     # Sidebar navigation
|   |   |-- lib/supabase.js           # Supabase client
|
|-- jetson/                           # Jetson Edge Deployment
|   |-- Dockerfile                    # L4T TensorRT container
|   |-- app/                          # main.py, inference.py, camera.py, database.py, sync_engine.py
|   |-- config/config.json            # Camera, models, sync settings
|   |-- agrikd.service                # Systemd unit file
|   |-- setup_jetson.sh               # One-click setup
|
|-- database/migrations/              # SQL migrations (15 files)
|   |-- 001_tables.sql                # Core tables (predictions, models, profiles, audit_log)
|   |-- 002_functions_triggers.sql    # Server-side RPCs + triggers
|   |-- 003_rls_policies.sql          # RLS policies + admin helpers
|   |-- 004_indexes.sql               # Performance indexes
|   |-- 005_storage.sql               # Storage buckets + policies
|   |-- 006_model_reports_and_rpcs.sql # Model reports table + dashboard RPCs
|   |-- 007_multi_version.sql         # Multi-version model registry + pipeline_runs
|   |-- 008_cleanup_and_realtime.sql  # Enum cleanup, benchmarks constraints, realtime
|   |-- 009_security_hardening.sql    # SET search_path on SECURITY DEFINER functions
|   |-- 010_fix_lifecycle_for_update.sql # Lifecycle trigger fix for UPDATE
|   |-- 011_dvc_operations.sql        # DVC operations tracking table
|   |-- 012_devices.sql               # Device management, provisioning tokens, Device Shadow
|   |-- 013_model_engines.sql         # Model engines (TensorRT), ONNX URL, engine RPCs
|   |-- 014_audit_fixes.sql           # Admin guards on RPCs, profile/report policies
|   |-- 015_audit_log_cleanup.sql     # audit_log schema normalization
|
|-- .github/workflows/               # CI/CD (13 workflows)
|   |-- ci.yml                        # Lint, Test, Model Conversion, Build APK
|   |-- codeql.yml                    # CodeQL SAST security scanning (JS/TS, Python)
|   |-- release.yml                   # GitHub Release + APK
|   |-- model-pipeline.yml            # Full conversion + benchmark + upload
|   |-- model-rollback.yml            # Rollback model to previous version
|   |-- validate-model.yml            # Validate + benchmark a specific model
|   |-- train.yml                     # Run full training pipeline
|   |-- dvc-pull.yml                  # Pull datasets from GCS
|   |-- dvc-push.yml                  # Push datasets to GCS
|   |-- dataset-upload.yml            # Add new dataset from GDrive/Kaggle or predictions
|   |-- deploy.yml                    # Trigger Vercel deployment
|   |-- export-data.yml               # Export predictions from Supabase
|
|-- mobile_app/test/                  # Flutter tests (89 tests)
|   |-- unit/                         # 6 files, 36 tests
|   |-- dao/                          # 1 file, 21 tests
|   |-- provider/                     # 2 files, 13 tests
|   |-- integration/                  # 1 file, 15 tests (OTA flow)
|   |-- widget_test.dart              # 4 widget tests
|   |-- test_helper.dart              # Test infrastructure
|
|-- android/, ios/, web/, windows/    # Flutter platform dirs
|-- pubspec.yaml                      # Flutter dependencies
|-- docs/
|   |-- technical/
|   |   |-- build_plan.md             # Implementation log & progress
|   |   |-- project_instruction.md    # This file
|   |   |-- project_context.md        # Project context & background
|   |-- guides/
|       |-- admin_dashboard_manual.md # Admin dashboard user guide
|       |-- jetson_deployment_guide.md # Jetson edge deployment guide
|       |-- product_release.md        # Product release checklist
|       |-- cicd_setup.md             # CI/CD pipeline setup guide
|       |-- flutter_app_build.md      # Flutter build instructions
|       |-- mlops_pipeline_setup.md   # MLOps pipeline setup guide
|       |-- supabase_setup.md         # Supabase setup guide
|-- venv_mlops/                       # Python venv (git-ignored)
```

---

## 4. MLOps Pipeline

### 4.1 Conversion Flows

**Flow 1: Mobile App (da hoan thanh)**
```
.pth  -->  ONNX (opset 17)  -->  TFLite (onnx2tf)
```
- `onnx2tf` tu dong chuyen NCHW -> NHWC cho TFLite
- Compression: ~48-49% (1.9 MB ONNX -> 0.95 MB TFLite)

**Flow 2: Jetson Edge Server**
```
.pth  -->  ONNX (opset 17)  -->  TensorRT Engine (trtexec)
```
- **PHAI chay tren Jetson** vi engine file phu thuoc vao GPU architecture
- FP16 precision cho hieu nang toi uu
- Script: `convert_onnx_to_tensorrt.py --method trtexec`

**Flow 3: Direct PTH -> TFLite (alternative, Linux only)**
```
.pth  -->  TFLite (ai-edge-torch)
```
- Chi hoat dong tren Linux (ai-edge-torch khong ho tro Windows)
- Script: `convert_pth_to_tflite.py`

### 4.2 Config-Driven Workflow

Moi loai la cay co 1 file config JSON chua toan bo metadata:
```json
{
    "leaf_type": "tomato",
    "display_name": "Ca chua (Tomato)",
    "num_classes": 10,
    "input_size": [224, 224],
    "checkpoint_filename": "tomato_student.pth",
    "data_dir": "data/tomato",
    "classes": { ... },
    "normalization": { "mean": [...], "std": [...] }
}
```

**Chay pipeline chi can 1 lenh:**
```bash
cd mlops_pipeline/scripts
python run_pipeline.py --config ../configs/tomato.json
```

Pipeline tu dong thuc hien:
1. PTH -> ONNX (convert + validate output)
2. ONNX -> TFLite (convert + report compression)
3. Cross-format validation (PyTorch vs ONNX vs TFLite)
4. Benchmark evaluation (accuracy, latency, confusion matrix, charts)

### 4.3 Them dataset moi

De them mot loai la moi, chi can:
1. **Tao config JSON** tai `mlops_pipeline/configs/<leaf_type>.json`
   - Dinh nghia classes theo **ImageFolder alphabetical sort**
   - Set `checkpoint_filename`, `data_dir`, `num_classes`
2. **Dat checkpoint** tai `model_checkpoints_student/<leaf_type>_student.pth`
3. **Dat dataset** tai `data/<leaf_type>/` (ImageFolder format)
4. **Chay pipeline**: `python run_pipeline.py --config ../configs/<leaf_type>.json`
5. **Cap nhat model_registry.json** them entry moi

> Pipeline se tu dong tao folder `models/<leaf_type>/` voi ONNX, TFLite, benchmark report va charts.

### 4.4 Benchmark Results

#### Tomato (10 classes, 242 test samples)
| Format | Size(MB) | Params(M) | FLOPs(M) | ms/img | FPS | Runtime Mem(MB) | Top-1% | KL Div |
|--------|----------|-----------|----------|--------|-----|-----------------|--------|--------|
| PyTorch | 1.99 | 0.49 | 374.7 | 34.35 | 29.1 | 4.5 | 87.2 | 0.000000 |
| ONNX | 1.87 | 0.49 | 374.7 | 5.12 | 195.2 | 12.1 | 87.2 | 0.000000 |
| TFLite | 0.96 | 0.49 | 374.7 | 11.25 | 88.9 | 12.1 | 87.6 | 0.000011 |

#### Burmese Grape Leaf (5 classes, 464 test samples)
| Format | Size(MB) | Params(M) | FLOPs(M) | ms/img | FPS | Runtime Mem(MB) | Top-1% | KL Div |
|--------|----------|-----------|----------|--------|-----|-----------------|--------|--------|
| PyTorch | 1.98 | 0.49 | 374.7 | 30.33 | 33.0 | 3.9 | 87.3 | 0.000000 |
| ONNX | 1.87 | 0.49 | 374.7 | 3.69 | 270.7 | 11.8 | 87.3 | 0.000000 |
| TFLite | 0.96 | 0.49 | 374.7 | 7.53 | 132.9 | 12.2 | 87.1 | 0.000002 |

### 4.5 Giai thich cac Metrics

| Metric | Y nghia |
|---|---|
| Size (MB) | Kich thuoc file model tren disk. TFLite nho nhat nho FlatBuffers serialization |
| Params (M) | So luong tham so (weights) cua model. **GIONG NHAU** cho ca 3 format vi cung kien truc, cung weights — conversion khong thay doi kien truc |
| FLOPs (M) | So phep tinh dau phay dong (Floating-point Operations). **GIONG NHAU** vi cung phep toan |
| ms/img | Thoi gian trung binh de inference 1 anh (mili-giay). Thap hon = nhanh hon |
| FPS | So anh xu ly duoc trong 1 giay (= 1000 / ms_per_img). Cao hon = nhanh hon |
| Runtime Mem (MB) | Delta bo nho RSS cua process khi load + chay model. Do doc lap cho moi format (gc.collect giua cac format) |
| Top-1 % | Phan tram mau ma class co xac suat **cao nhat** khop voi nhan that (ground truth) — chinh la **Accuracy** |
| KL Div | KL Divergence — do muc sai khac **toan bo phan phoi xac suat** (khong chi argmax) so voi PyTorch goc. Gia tri ~0 xac nhan conversion khong mat thong tin |

**Vi sao Top-1% khac nhau nhung KL Div van ~ 0?**
- KL Div do sai khac **toan bo vector xac suat** (VD: 10 gia tri cho Tomato), con Top-1% chi xem **argmax** (class nao cao nhat)
- Khi mot mau nam sat ranh gioi quyet dinh (VD: PyTorch `[0.350001, 0.349999]` vs TFLite `[0.349999, 0.350001]`), phan phoi xac suat gan nhu giong nhau (KL ~ 0) nhung argmax bi dao → Top-1% thay doi
- Day la hien tuong **"boundary flip"** — chi anh huong 1-2 mau, khong phai loi conversion

**Luu y quan trong ve benchmark tren Desktop vs Mobile:**
- Benchmark chay tren **x86 Desktop CPU** (khong phai ARM mobile)
- **ONNX Runtime co FPS cao nhat tren desktop** vi duoc toi uu cho x86 (AVX/SSE instructions)
- **TFLite co FPS thap hon ONNX tren desktop** nhung la format toi uu cho **ARM mobile** — tren dien thoai se nhanh hon nhieu nho GPU Delegate va NNAPI
- Nhung metric FPS va Runtime Mem **khong phan anh hieu nang thuc te tren mobile** — chi mang tinh tham khao cross-format consistency

> Chi tiet: xem `models/<leaf_type>/benchmark_report.md`

---

## 5. Flutter App Architecture

### 5.1 Technology Stack
| Thanh phan | Cong nghe | Ly do |
|---|---|---|
| Framework | Flutter | Cross-platform, offline-capable, native performance |
| State Management | Riverpod | Compile-safe, testable, scalable |
| Local Database | sqflite | SQLite cho Flutter, mature, reliable |
| ML Inference | tflite_flutter | TFLite interpreter cho Flutter |
| Camera | camera + image_picker | Real-time preview + gallery selection |
| Connectivity | connectivity_plus | Detect online/offline status |
| Security | crypto | SHA-256 model integrity verification |
| Permissions | permission_handler | Camera/storage permissions |

### 5.2 Dependencies (pubspec.yaml)
```yaml
dependencies:
  flutter:
    sdk: flutter
  # State management
  flutter_riverpod: ^2.6.1
  # Database
  sqflite: ^2.4.1
  path: ^1.9.0
  # ML Inference
  tflite_flutter: ^0.12.1
  # Camera & Image
  camera: ^0.11.0+2
  image_picker: ^1.1.2
  image: ^4.3.0         # Image processing (resize, normalize)
  # Networking & Sync
  connectivity_plus: ^6.1.0
  # Auth
  google_sign_in: ^6.2.1
  # Backend
  supabase_flutter: ^2.9.0
  # Security
  crypto: ^3.0.6
  path_provider: ^2.1.0
  # Permissions
  permission_handler: ^11.3.1
  # UI
  cupertino_icons: ^1.0.8
  fl_chart: ^0.69.2     # Charts for history/stats
  intl: ^0.19.0         # Date formatting
  sqflite_common_ffi_web: ^1.1.1  # Web SQLite support

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  sqflite_common_ffi: ^2.3.4+4   # Desktop SQLite for testing
```

### 5.3 Clean Architecture
```
lib/
|-- main.dart                    # App entry point, ProviderScope
|-- core/
|   |-- constants/
|   |   |-- app_constants.dart   # Image size, normalization values
|   |   |-- model_constants.dart # Model paths, class labels
|   |-- theme/
|   |   |-- app_theme.dart       # Material theme, colors
|   |-- utils/
|       |-- image_preprocessor.dart  # Replicate PyTorch transform
|       |-- model_integrity.dart     # SHA-256 checksum verification
|
|-- features/
|   |-- diagnosis/
|   |   |-- presentation/
|   |   |   |-- screens/
|   |   |   |   |-- home_screen.dart         # Chon loai la
|   |   |   |   |-- camera_screen.dart       # Chup/chon anh
|   |   |   |   |-- result_screen.dart       # Ket qua chan doan
|   |   |   |-- widgets/
|   |   |       |-- leaf_type_card.dart
|   |   |-- domain/
|   |   |   |-- models/
|   |   |   |   |-- prediction.dart
|   |   |   |   |-- leaf_model.dart
|   |   |   |-- repositories/
|   |   |       |-- diagnosis_repository.dart
|   |   |-- data/
|   |       |-- diagnosis_repository_impl.dart
|   |       |-- tflite_inference_service.dart
|   |
|   |-- history/
|   |   |-- presentation/
|   |   |   |-- screens/
|   |   |       |-- history_screen.dart      # Lich su chan doan
|   |   |       |-- detail_screen.dart       # Chi tiet 1 prediction
|   |   |-- domain/
|   |   |-- data/
|   |
|   |-- settings/
|       |-- presentation/
|       |   |-- screens/
|       |       |-- settings_screen.dart     # Cai dat app
|       |-- domain/
|       |-- data/
|
|-- data/
    |-- database/
    |   |-- app_database.dart       # SQLite init, migrations
    |   |-- dao/
    |       |-- prediction_dao.dart
    |       |-- model_dao.dart
    |-- sync/
        |-- sync_service.dart       # Background sync engine
        |-- sync_queue.dart         # Queue management
```

### 5.4 Screens & User Flow
```
Screens (14):
  Home, Camera, Result, History, Detail, Stats, Settings, Benchmark,
  Login, Register, ForgotPassword, ResetPassword
  + 4 stub/mobile variants (camera, file_helper, image_widget, tflite_inference)

[Home Screen] (bottom nav: Home / History / Settings)
    |-- Chon loai la (Tomato / Burmese / ...)
    |-- Nhan "Chup anh" / "Chon tu thu vien"
    v
[Camera Screen] (live preview + gallery)
    |-- Chup anh / chon anh tu gallery
    v
[Inference] (compute() isolate)
    |-- Resize 224x224 + Normalize (ImageNet)
    |-- TFLite interpreter.run() (GPU→XNNPack→CPU)
    |-- Softmax -> class index + confidence
    v
[Result Screen]
    |-- Ten benh, do tin cay, anh goc
    |-- fl_chart BarChart cac class probabilities
    |-- Notes, Luu / Chup lai / Xem lich su

[History Screen]               [Stats Screen]
    |-- Paginated list              |-- Overview stats
    |-- Search, filter chips        |-- Daily bar chart (7 days)
    |-- Tap → Detail Screen         |-- Top diseases pie chart

[Settings Screen]
    |-- Account info (login/logout)
    |-- Sync status (syncing / last synced / failed)
    |-- Default crop, auto-sync, theme, language
    |-- Benchmark screen

[Auth Flow]
    Login → Register (Email/Google)
            |
            v (forgot password)
    ForgotPassword → (email sent) → User click email link
            |
            v (deep link com.agrikd.app://callback)
    ResetPassword → (update password) → Authenticated
```

### 5.5 TFLite Integration

#### Model Loading
```dart
// Load model voi integrity check
final modelFile = 'assets/models/tomato/tomato_student.tflite';
final checksum = await ModelIntegrity.sha256(modelFile);
assert(checksum == expectedChecksum, 'Model integrity check failed!');

final interpreter = await Interpreter.fromAsset(modelFile);
```

#### Image Preprocessing (replicate PyTorch transform)
```dart
/// Replicate: Resize(224) -> ToTensor() -> Normalize(ImageNet)
Float32List preprocessImage(img.Image image) {
  // 1. Resize to 224x224
  final resized = img.copyResize(image, width: 224, height: 224);

  // 2. Convert to float [0, 1] and normalize (NHWC format for TFLite)
  final input = Float32List(1 * 224 * 224 * 3);
  const mean = [0.485, 0.456, 0.406];
  const std = [0.229, 0.224, 0.225];

  for (int y = 0; y < 224; y++) {
    for (int x = 0; x < 224; x++) {
      final pixel = resized.getPixel(x, y);
      final idx = (y * 224 + x) * 3;
      input[idx + 0] = (pixel.r / 255.0 - mean[0]) / std[0]; // R
      input[idx + 1] = (pixel.g / 255.0 - mean[1]) / std[1]; // G
      input[idx + 2] = (pixel.b / 255.0 - mean[2]) / std[2]; // B
    }
  }
  return input;
}
```

#### Inference
```dart
// TFLite output: [1, num_classes] (raw logits)
var output = List.filled(1 * numClasses, 0.0).reshape([1, numClasses]);
interpreter.run(inputTensor, output);

// Softmax
final logits = output[0] as List<double>;
final maxLogit = logits.reduce(max);
final exps = logits.map((l) => exp(l - maxLogit)).toList();
final sumExp = exps.reduce((a, b) => a + b);
final probs = exps.map((e) => e / sumExp).toList();

// Get prediction
final classIndex = probs.indexOf(probs.reduce(max));
final confidence = probs[classIndex];
final className = classLabels[classIndex];
```

### 5.6 Model Bundling
```yaml
# pubspec.yaml - bundle TFLite models as assets
flutter:
  assets:
    - assets/models/tomato/tomato_student.tflite
    - assets/models/burmese_grape_leaf/burmese_grape_leaf_student.tflite
```
- Models duoc bundle truc tiep trong APK (~0.95 MB moi model)
- Khong can download khi cai app lan dau
- Ho tro OTA update (xem muc 9.3)

### 5.7 TFLite Delegates (Hardware Acceleration tren Mobile)

Tren dien thoai, CPU thuong yeu nhung GPU/NPU lai manh. TFLite ho tro **Delegates** de tan dung phan cung chuyen dung, tang toc inference dang ke.

#### Cac loai Delegate
| Delegate | Platform | Toc do (so voi CPU) | Ghi chu |
|---|---|---|---|
| CPU (default) | Android + iOS | 1x (baseline) | Luon hoat dong, ~7ms tren desktop |
| GPU Delegate | Android + iOS | 2-5x nhanh hon | OpenGL ES (Android), Metal (iOS) |
| NNAPI | Chi Android 8.1+ | 3-10x nhanh hon | Routes to NPU/DSP/GPU tuy chipset |
| Hexagon DSP | Chi Qualcomm | 5-15x nhanh hon | Can Snapdragon SoC |
| Core ML | Chi iOS | 3-8x nhanh hon | Apple Neural Engine |

> Model AgriKD chi ~0.49M params va ~375 MFLOPs — rat nhe. Voi bat ky delegate nao, inference se **< 5ms** tren dien thoai trung binh.

#### Code su dung Delegate
```dart
import 'package:tflite_flutter/tflite_flutter.dart';

// Option 1: GPU Delegate (Android: OpenGL ES, iOS: Metal)
final gpuDelegate = GpuDelegateV2();
final gpuOptions = InterpreterOptions()..addDelegate(gpuDelegate);
final interpreter = await Interpreter.fromAsset(modelPath, options: gpuOptions);

// Option 2: NNAPI Delegate (Android only — routes to NPU/DSP/GPU)
final nnapiDelegate = NnApiDelegate();
final nnapiOptions = InterpreterOptions()..addDelegate(nnapiDelegate);
final interpreter = await Interpreter.fromAsset(modelPath, options: nnapiOptions);
```

#### Chien luoc Delegate Fallback (khuyen nghi)
```
App khoi dong → Load model:
  1. Thu GPU Delegate
     ✓ Thanh cong → dung GPU, ghi vao user_preferences
     ✗ Fail → buoc 2
  2. Thu XNNPack Delegate
     ✓ Thanh cong → dung XNNPack, ghi vao user_preferences
     ✗ Fail → buoc 3
  3. Fallback CPU (luon hoat dong)
     → Ghi vao user_preferences

Lan sau mo app → Doc user_preferences, dung delegate da luu (skip retry)
```

> **Luu y**: `NnApiDelegate` khong co trong `tflite_flutter 0.12.1`. App su dung XNNPack thay the.
> NNAPI va cac delegate khac (Hexagon DSP, CoreML) chi mang tinh tham khao trong bang tren.

#### Tai sao FPS tren Desktop khong dai dien cho Mobile?
- **ONNX Runtime** toi uu cho x86 CPU voi AVX-512/SSE instructions → FPS cao nhat tren PC
- **TFLite** toi uu cho ARM CPU + ho tro hardware delegates → tren mobile se **vuot troi** ONNX
- Benchmark desktop chi co gia tri so sanh **cross-format consistency** (accuracy, KL Div), **KHONG** phan anh toc do thuc te tren thiet bi target

---

## 6. Database Schema (SQLite - sqflite)

### 6.1 predictions
Luu lich su chan doan cua nguoi dung.
```sql
CREATE TABLE predictions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    image_path      TEXT NOT NULL,           -- Duong dan anh goc (local)
    leaf_type       TEXT NOT NULL,           -- 'tomato', 'burmese_grape_leaf'
    model_version   TEXT NOT NULL,           -- '1.0.0'

    predicted_class_index  INTEGER NOT NULL, -- 0-9 (Tomato) hoac 0-4 (Burmese)
    predicted_class_name   TEXT NOT NULL,    -- 'Bacterial_spot', 'Healthy', ...
    confidence      REAL NOT NULL,           -- 0.0 - 1.0
    all_confidences TEXT,                    -- JSON array cua tat ca class probs

    inference_time_ms REAL,                 -- Thoi gian inference (ms)

    latitude        REAL,                    -- GPS (nullable, khi co permission)
    longitude       REAL,
    notes           TEXT,                    -- Ghi chu cua user (nullable)

    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    is_synced       INTEGER NOT NULL DEFAULT 0,  -- 0: chua sync, 1: da sync
    synced_at       TEXT,
    server_id       TEXT                     -- ID tu server sau khi sync
);

CREATE INDEX idx_predictions_leaf_type ON predictions(leaf_type);
CREATE INDEX idx_predictions_created_at ON predictions(created_at);
CREATE INDEX idx_predictions_is_synced ON predictions(is_synced);
```

### 6.2 models
Quan ly cac model da cai dat tren thiet bi (multi-version, max 2 active per leaf_type).
```sql
CREATE TABLE models (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    leaf_type       TEXT NOT NULL,
    version         TEXT NOT NULL,
    file_path       TEXT NOT NULL,           -- Duong dan TFLite file
    sha256_checksum TEXT NOT NULL,           -- Verify truoc khi load
    num_classes     INTEGER NOT NULL,
    class_labels    TEXT NOT NULL,           -- JSON array
    accuracy_top1   REAL,                    -- Accuracy benchmark
    is_bundled      INTEGER NOT NULL DEFAULT 1,  -- 1: trong APK, 0: downloaded
    is_active       INTEGER NOT NULL DEFAULT 1,  -- Model dang duoc su dung
    role            TEXT NOT NULL DEFAULT 'active'
                    CHECK (role IN ('active', 'fallback', 'archived')),
    is_selected     INTEGER NOT NULL DEFAULT 0,  -- 1: version dang dung cho inference
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(leaf_type, version)
);
```

### 6.3 user_preferences
Cai dat nguoi dung (key-value).
```sql
CREATE TABLE user_preferences (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Default entries:
-- key: 'default_leaf_type', value: 'tomato'
-- key: 'auto_sync', value: 'true'
-- key: 'theme', value: 'system'
-- key: 'save_images', value: 'true'
-- key: 'gps_enabled', value: 'false'
```

### 6.4 sync_queue
Hang doi sync khi co mang.
```sql
CREATE TABLE sync_queue (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type   TEXT NOT NULL,      -- 'prediction'
    entity_id     INTEGER NOT NULL,   -- ID trong bang predictions
    action        TEXT NOT NULL,      -- 'create', 'update', 'delete'
    payload       TEXT,               -- JSON data de gui len server
    retry_count   INTEGER NOT NULL DEFAULT 0,
    max_retries   INTEGER NOT NULL DEFAULT 3,
    status        TEXT NOT NULL DEFAULT 'pending',
        -- 'pending', 'in_progress', 'completed', 'failed'
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at  TEXT
);

CREATE INDEX idx_sync_queue_status ON sync_queue(status);
```

---

## 7. Security & Optimization (Zero Cost)

### 7.1 Model Integrity
- SHA-256 checksum cho moi file .tflite truoc khi load vao interpreter
- Checksums luu trong `model_registry.json` va bang `models` trong SQLite
- Neu checksum khong khop -> reject model, su dung model bundled

### 7.2 Input Validation
- Chi chap nhan JPEG/PNG
- File size < 10 MB
- Validate image dimensions truoc khi process
- Sanitize file paths (tranh path traversal)

### 7.3 Local Data Protection
- SQLite chua encrypt (sqflite). Da danh gia `sqflite_sqlcipher` — khuyen nghi implement khi publish Play Store
- Credentials (Supabase URL, anon key) inject qua `--dart-define-from-file` (build-time, khong commit vao code)
- App khong luu thong tin ca nhan (ten, email) — chi prediction data

### 7.4 Network Security
- HTTPS (TLS 1.2+) cho tat ca sync requests
- Jetson sync qua HTTP REST to Supabase (TLS)
- Images nen < 200KB truoc upload qua Supabase Storage (JPEG quality progressive)

### 7.5 Code & Dependencies
- Khong commit secrets (.env, API keys, credentials) — da co trong .gitignore
- `pip audit` / `safety check` dinh ky cho Python dependencies
- `dart analyze` cho Flutter code
- Khong su dung eval(), exec() hoac dynamic code execution

---

## 8. Admin vs User Flows

### 8.1 User Flow (Mobile App)
```
1. Mo app -> Chon loai la cay
2. Chup anh hoac chon tu gallery
3. App chay inference offline (TFLite) -> Ket qua trong < 100ms
4. Hien thi: Ten benh + do tin cay + cac class khac
5. Luu vao history (SQLite)
6. Khi co mang -> Auto-sync predictions len server (background)
7. Xem lai lich su, filter, tim kiem
```

**Tinh nang user:**
- Chon loai la (dropdown/grid)
- Chup/chon anh
- Xem ket qua chi tiet (bar chart probabilities)
- Xem lich su chan doan
- Cai dat: loai la mac dinh, auto-sync on/off, theme
- Xem thong ke ca nhan (so lan chup, benh pho bien)

### 8.2 Admin Flow — ✅ DA TRIEN KHAI
- **Admin Dashboard** (web, React + Vite + Supabase JS):
  - Directory: `admin-dashboard/`
  - Tech: React 18, react-router-dom, recharts, @supabase/supabase-js
  - Deploy: Vercel hoac GitHub Pages

- **Screens (10 trang, bao gom Login):**
  - Login: Email/password (admin account)
  - Dashboard: Aggregated stats (server-side RPCs) + BarChart daily scans + PieChart disease distribution
  - Predictions: Paginated table 25/page, filters (leaf type, date range), Export CSV/JSON (max 10000 rows)
  - Models: Model registry management (5 tabs: Registry, Compare, Upload, Pipeline, Benchmarks). Multi-version support with staging/active/backup lifecycle. Upload .pth checkpoints, trigger CI/CD pipeline, compare model versions, view benchmark metrics.
  - Users: Danh sach nguoi dung, so predictions, ngay tham gia, trang thai admin
  - Data Management: Quan ly datasets, export/import du lieu, DVC operations
  - Releases: Quan ly cac phien ban phat hanh, APK, release notes
  - System Health: Trang thai he thong, Supabase metrics, storage usage, sync stats
  - Model Reports: Benchmark reports, accuracy trends, cross-format comparison
  - Settings: Cau hinh admin dashboard, notifications, system preferences

- **Admin RLS:**
  - `database/migrations/002_rls_policies.sql`
  - `is_admin()` function kiem tra email admin
  - Admin co the doc tat ca predictions va storage objects

- **Khong can backend phuc tap**:
  - Dung Supabase Free Tier (PostgreSQL + Auth + REST API)
  - Dashboard doc data tu Supabase truc tiep

---

## 9. Online/Offline Behavior

### 9.1 Offline (mac dinh)
App hoat dong day du khong can internet:
- Models bundled trong APK -> inference offline 100%
- Predictions luu vao SQLite local
- History browsing, search, filter — tat ca offline
- Camera chup/pick tu gallery — offline
- **Khong can dang nhap**, khong can tai kinh

### 9.2 Online (opportunistic)
Khi phat hien co mang (qua `connectivity_plus`):
```dart
// Kiem tra connectivity
final result = await Connectivity().checkConnectivity();
if (result != ConnectivityResult.none) {
    await syncService.pushPendingPredictions();
    await syncService.checkModelUpdates();
}
```

- **Push predictions**: Gui cac record chua sync len server (batch 50)
- **Model update check**: So sanh local version vs remote `model_registry.json`
- **Retry logic**: Max 3 retries, exponential backoff
- Tat ca sync chay background, khong block UI

### 9.3 Model OTA Update — ✅ DA TRIEN KHAI
File: `lib/data/sync/supabase_sync_service.dart` — method `downloadModelUpdate()`

```
1. checkModelUpdates() so sanh local vs remote model_registry
2. Neu co version moi (fileUrl != null):
   a. Download .tflite tu Supabase Storage (models bucket)
   b. Verify SHA-256 checksum (ModelIntegrity.sha256Bytes)
   c. Luu vao local storage (path_provider → app documents)
   d. Cap nhat bang 'models' trong SQLite (ModelDao.updateVersion)
3. Giu model cu lam fallback neu download fail
```

> **Luu y**: OTA la optional. Models bundled trong APK la du de su dung. OTA chi can khi co model moi sau release.

---

## 10. Zero-Cost Deployment Strategy

| Component | Service | Cost | Notes |
|---|---|---|---|
| App Distribution | Google Play / Direct APK | Free | APK download qua GitHub Releases |
| Admin Dashboard | GitHub Pages / Vercel | Free | Static site, Supabase client |
| Sync Backend | Supabase Free Tier | Free | 500 MB DB, 50k monthly requests |
| Model Hosting | GitHub Releases | Free | .tflite files < 2 GB each |
| MQTT Broker (IoT) | Eclipse Mosquitto | Free | Self-hosted tren Jetson hoac VPS |
| CI/CD | GitHub Actions | Free | Public repo unlimited minutes |
| Data Storage | Google Cloud Storage (DVC) | Free | 5 GB free (us-east1) |
| Monitoring | GitHub Issues + Logs | Free | Manual monitoring |

**Tong chi phi: 0 VND/thang**

> Neu scale lon (>50k requests/thang), co the upgrade Supabase ($25/thang) hoac chuyen sang Firebase Blaze (pay-as-you-go, ~$0 cho luong nho).

---

## 11. Jetson Edge Deployment — ✅ DA TRIEN KHAI

Directory: `jetson/`

### 11.1 Docker Container
```dockerfile
# Base: NVIDIA L4T TensorRT (official)
FROM nvcr.io/nvidia/l4t-tensorrt:r8.5.2-runtime
# Non-root user (agrikd), Python deps, HEALTHCHECK
```

Files:
- `Dockerfile`: Production container
- `app/main.py`: Main loop (manual/periodic modes, signal handling)
- `app/inference.py`: TensorRT FP16 inference (PyCUDA, ImageNet norm)
- `app/camera.py`: USB/CSI camera capture (OpenCV)
- `app/database.py`: SQLite WAL mode database
- `app/sync_engine.py`: HTTP sync to Supabase REST API (batch 50)
- `app/health_server.py`: Flask REST API
- `config/config.json`: All settings (camera, models, sync, logging)
- `agrikd.service`: Systemd unit file (auto-start, restart, resource limits)
- `setup_jetson.sh`: One-click deployment script

### 11.2 Inference Flow
```
Camera (USB/CSI) -> Capture frame
    -> Resize 224x224 + Normalize (ImageNet)
    -> TensorRT FP16 inference (~1-2ms via PyCUDA)
    -> Argmax + Softmax -> prediction
    -> Save to SQLite + sync queue
```

### 11.3 Camera Modes (configurable)
- **Manual Mode**: Trigger qua REST API (`POST /predict` voi image upload)
- **Periodic Mode**: Timer configurable (e.g., moi 30 phut)
- Config qua `config/config.json`

### 11.4 Sync Engine
```
Background thread (daemon):
1. Query SQLite: SELECT * FROM predictions WHERE is_synced = 0 LIMIT 50
2. HTTP POST to Supabase REST API (/rest/v1/predictions)
3. Nhan 201 -> UPDATE predictions SET is_synced = 1
4. Sleep interval_seconds -> Loop
```

### 11.5 Operations
- **Systemd service**: Auto-start on boot, restart on crash (RestartSec=10)
- **Log rotation**: Max 100 MB, 5 backup files (RotatingFileHandler)
- **Health check**: `GET /health` tren port 8080 (uptime, models loaded, DB stats)
- **SQLite WAL mode**: Crash-safe concurrent reads/writes
- **REST API**: `/predict` (POST image), `/stats` (GET), `/health` (GET)

### 11.6 Setup
```bash
cd jetson
sudo chmod +x setup_jetson.sh
sudo ./setup_jetson.sh    # Creates user, installs deps, converts models, installs service
sudo systemctl start agrikd
curl http://localhost:8080/health
```

---

## 12. CI/CD Pipeline (GitHub Actions) — ✅ DA TRIEN KHAI

### 12.1 Workflows Overview (13 workflows)

**Automatic workflows** (triggered boi push/PR):

| Workflow | File | Trigger | Muc dich |
|----------|------|---------|----------|
| **CI** | `ci.yml` | Push to `main`/`release/*`, PRs to `main` | Lint, test, build APK |
| **Release** | `release.yml` | Push tag `v*` | Build APK + create GitHub Release |

**Manual workflows** (workflow_dispatch):

| Workflow | File | Muc dich |
|----------|------|----------|
| **Model Pipeline** | `model-pipeline.yml` | Full conversion + benchmark + upload to Supabase |
| **Model Rollback** | `model-rollback.yml` | Rollback model to previous version |
| **Validate Model** | `validate-model.yml` | Validate + benchmark a specific model |
| **Train** | `train.yml` | Run full training pipeline |
| **DVC Pull** | `dvc-pull.yml` | Pull datasets from GCS |
| **DVC Push** | `dvc-push.yml` | Push datasets to GCS |
| **Dataset Upload** | `dataset-upload.yml` | Add new dataset from GDrive/Kaggle or predictions |
| **Deploy** | `deploy.yml` | Trigger Vercel deployment for admin dashboard |
| **Export Data** | `export-data.yml` | Export predictions from Supabase |

> Chi tiet cau hinh: xem `docs/guides/cicd_setup.md`

### 12.2 Trigger
- **CI** (`ci.yml`): Push/PR len branch `main` hoac `release/*`
- **Release** (`release.yml`): Push tag `v*` (e.g., `v1.0.0`)
- Model conversion chi chay khi commit message chua `[model]` hoac thay doi `mlops_pipeline/`

### 12.3 CI Pipeline Stages (da implement)

**File: `.github/workflows/ci.yml`** — 5 stages:

| Stage | Job | Mo ta |
|-------|-----|-------|
| 1. Lint | `lint` | `dart format --set-exit-if-changed` + `flutter analyze` |
| 2. Test | `test` | `flutter test` (89 tests), can `libsqlite3-dev` |
| 3. Model Conversion | `model-conversion` | `run_pipeline.py` cho Tomato + Burmese, upload artifacts |
| 4. Model Validation | `model-validation` | `validate_models.py` + `evaluate_models.py` |
| 5. Build APK | `build` | `flutter build apk --release` voi `--dart-define` Supabase secrets |

**File: `.github/workflows/release.yml`** — Stage 6:

| Stage | Mo ta |
|-------|-------|
| 6. Release | Test → Build APK → Create GitHub Release voi APK attached |

### 12.4 Secrets can cau hinh
- `SUPABASE_URL` — Supabase project URL
- `SUPABASE_ANON_KEY` — Supabase anonymous key

### 12.5 Self-Hosted Runner (Jetson)
- Cai GitHub Actions runner tren Jetson (se them khi setup Jetson deployment)
- Test TensorRT conversion truc tiep tren hardware
- Verify .engine file hoat dong dung

---

## 13. Model Registry & Versioning

### 13.1 model_registry.json
Central index luu tai `mlops_pipeline/configs/model_registry.json`:
```json
{
    "version": "1.0.0",
    "models": {
        "tomato": {
            "num_classes": 10,
            "version": "1.0.0",
            "formats": {
                "pth": "model_checkpoints_student/tomato_student.pth",
                "onnx": "models/tomato/tomato_student.onnx",
                "tflite": "models/tomato/tomato_student.tflite"
            }
        }
    }
}
```

### 13.2 Versioning Strategy
- **Semver** (v1.0.0): MAJOR.MINOR.PATCH
  - MAJOR: Architecture thay doi (so class khac, backbone khac)
  - MINOR: Re-train voi data moi, accuracy cai thien
  - PATCH: Bug fix, conversion update
- Moi version co: checksum, accuracy metrics, conversion date
- Git tags: `model/tomato/v1.0.0`

### 13.3 Data Version Control (DVC) — ✅ DA SETUP
Files: `.dvc/config`, `data_tomato.dvc`, `data_burmese_grape_leaf.dvc`

```bash
# DVC da duoc khoi tao voi Google Cloud Storage remote
# Remote: gs://agrikd-dvc-data/data

# Sau khi config xong:
dvc push                  # Upload datasets to remote
dvc pull                  # Download datasets from remote

# Khi co du lieu moi:
dvc add data/tomato
dvc push
git add data_tomato.dvc
git commit -m "Update tomato dataset v2"
```

---

## 14. MLOps Enhancements (Planned)

> **Luu y**: Cac tinh nang duoi day la **du kien / chua implement**. Ghi lai day de dinh huong phat trien va lam tai lieu thiet ke.

### 14.1 Data Drift Detection (Planned)

**Muc dich**: Phat hien khi du lieu thuc te (production) lech khoi phan phoi training data, dan den giam chat luong du doan.

**Approach**: Theo doi phan phoi confidence score cua cac prediction theo thoi gian.

**Implementation**:
1. **Supabase RPC `get_confidence_stats(interval_days)`**: Tra ve avg, stddev, va histogram cua confidence scores trong khoang thoi gian chi dinh.
   ```sql
   -- Vi du RPC function
   CREATE OR REPLACE FUNCTION get_confidence_stats(interval_days INT DEFAULT 30)
   RETURNS JSON AS $$
   SELECT json_build_object(
     'avg_confidence', AVG(confidence),
     'stddev_confidence', STDDEV(confidence),
     'total_predictions', COUNT(*),
     'histogram', json_agg(json_build_object(
       'bucket', bucket,
       'count', cnt
     ))
   )
   FROM (
     SELECT
       width_bucket(confidence, 0, 1, 10) AS bucket,
       COUNT(*) AS cnt
     FROM predictions
     WHERE created_at >= NOW() - (interval_days || ' days')::INTERVAL
     GROUP BY bucket
   ) sub
   CROSS JOIN (
     SELECT AVG(confidence) AS confidence, STDDEV(confidence)
     FROM predictions
     WHERE created_at >= NOW() - (interval_days || ' days')::INTERVAL
   ) stats;
   $$ LANGUAGE sql SECURITY DEFINER;
   ```

2. **Admin Dashboard chart**: Trend line hien thi average confidence trong 30 ngay gan nhat. Hien thi tren trang Dashboard hoac Predictions.

3. **Alert threshold**: Khi avg confidence giam duoi **70%**, danh dau la "potential drift" tren Admin Dashboard.

4. **Gioi han**: Day la proxy nhe (lightweight proxy) cho data drift detection that su. True drift detection can so sanh phan phoi feature cua input data voi training data (vi du: dung Kolmogorov-Smirnov test hoac Population Stability Index). Cach nay chi phat hien khi mo hinh "khong tu tin" -- co the do data drift hoac domain shift.

### 14.2 Automated Retraining Trigger (Planned)

**Muc dich**: Tu dong canh bao admin khi co du feedback (model_reports) de xem xet re-train mo hinh.

**Approach**: Khi so luong model_reports cho mot version vuot qua threshold (mac dinh: 50), gui thong bao.

**Implementation options**:

1. **Option 1 -- Supabase Database Webhook**:
   - Cau hinh webhook tren bang `model_reports`
   - Khi `COUNT(*) WHERE version = X` vuot threshold, gui POST den URL da cau hinh
   - Uu diem: Real-time, khong can code them
   - Nhuoc diem: Can endpoint nhan webhook (co the dung Supabase Edge Function)

2. **Option 2 -- Supabase Edge Function (daily cron)**:
   - Edge Function chay hang ngay (cron), dem so report theo version
   - Khi vuot threshold, gui email hoac Slack notification
   ```typescript
   // Vi du Edge Function (Deno)
   const { data } = await supabase
     .from('model_reports')
     .select('leaf_type, version', { count: 'exact', head: true })
     .gte('created_at', thirtyDaysAgo)
   // Neu count > THRESHOLD -> gui alert
   ```
   - Uu diem: Don gian, kiem soat logic tot
   - Nhuoc diem: Khong real-time (chay 1 lan/ngay)

3. **Option 3 -- CI Workflow (manual trigger)**:
   - Admin xem reports tren dashboard, quyet dinh re-train
   - Trigger GitHub Actions workflow `retrain.yml` voi params: `leaf_type`, `version`
   - Workflow pull data tu DVC, chay KD training, push model moi
   - Uu diem: Admin kiem soat hoan toan
   - Nhuoc diem: Khong tu dong

**Gioi han**: Full automated retraining yeu cau:
- Training data pipeline (DVC pull + augmentation)
- GPU compute (GitHub Actions free tier khong co GPU; can self-hosted runner hoac cloud GPU)
- Validation gate truoc khi deploy (so sanh accuracy moi vs cu)
- Nhung yeu to nay vuot qua pham vi zero-cost cua du an

> **Khuyen nghi**: Bat dau voi Option 3 (manual trigger) vi don gian nhat va phu hop voi quy mo du an. Khi co nhieu nguoi dung hon, chuyen sang Option 2 (Edge Function cron).

---

## 15. Test Data Split

Cac benchmark duoc thuc hien tren test split:
- **Method**: `sklearn.model_selection.train_test_split`
- **Ratio**: 70% train / 15% val / 15% test
- **Seed**: 42 (fixed, reproducible)
- **Stratified**: Yes (giu ty le class)

> Script evaluate_models.py tu dong reproduce split nay de dam bao consistency voi KD training.

---

## 16. Quick Start

### MLOps Pipeline
```bash
# 1. Setup venv
python -m venv venv_mlops
source venv_mlops/bin/activate  # Windows: venv_mlops\Scripts\activate
pip install -r mlops_pipeline/requirements.txt

# 2. Chay pipeline cho 1 loai la
cd mlops_pipeline/scripts
python run_pipeline.py --config ../configs/tomato.json

# 3. Ket qua tai models/tomato/
#    - tomato_student.onnx
#    - tomato_student.tflite
#    - benchmark_report.md
#    - confusion_matrix_*.png
```

### Flutter App (hoan thanh)
```bash
# 1. Install dependencies
flutter pub get

# 2. Copy models vao assets/
mkdir -p assets/models/tomato
cp models/tomato/tomato_student.tflite assets/models/tomato/

# 3. Run (can .env voi Supabase credentials)
flutter run --dart-define-from-file=.env

# 4. Run tests
flutter test    # 89 tests across 11 files

# 5. Build release APK
flutter build apk --release --dart-define-from-file=.env
```

**Tinh nang app:**
- 13 screens: Home, Camera, Result, History, Detail, Stats, Settings, Benchmark, Devices, Login, Register, ForgotPassword, ResetPassword (+ 4 stub/mobile variants)
- Auth: Email/Password + Google Sign-In + Forgot/Reset Password + Deep Link (PKCE)
- Authentication: Email/Password + Google Sign-In (native)
- Inference: TFLite MobileNetV2 (GPU -> XNNPack -> CPU delegate fallback)
- Sync: Auto-sync (connectivity change, auth change, app resume), exponential backoff
- History: Filter (leaf type, date, confidence), text search, sort, pagination
- Result: fl_chart BarChart, notes, localized disease names
- Settings: Theme, language (EN/VI), default crop, auto backup
- Security: Magic bytes validation (JPEG/PNG), path traversal check, SHA-256 model integrity

---

## 17. Flutter Test Suite

### 17.1 Test Infrastructure
- **Test runner**: `flutter test` (dart test runner)
- **Dev dependency**: `sqflite_common_ffi: ^2.3.4+4` cho desktop SQLite
- **Shared helper**: `test/test_helper.dart`
  - `initTestDatabase()`: Khoi tao `databaseFactoryFfiNoIsolate` + set `AppDatabase.useInMemory = true`
  - `resetTestDatabase()`: Reset `AppDatabase` singleton de moi test group co DB moi
- **AppDatabase**:
  - `resetForTest()` (`@visibleForTesting`): Reset singleton
  - `useInMemory` (`@visibleForTesting`): Force in-memory DB (tranh file locking giua test files)

### 17.2 Test Files & Coverage

| # | File | Tests | Module |
|---|------|-------|--------|
| 1 | `test/unit/app_constants_test.dart` | 5 | imageSize, ImageNet mean/std, maxImageSizeBytes, syncBatchSize |
| 2 | `test/unit/app_strings_test.dart` | 8 | EN/VI strings, key fallback, fmt(), locale fallback, translation coverage |
| 3 | `test/unit/image_preprocessor_test.dart` | 4 | NHWC output shape, ImageNet normalization, file size validation |
| 4 | `test/unit/model_constants_test.dart` | 11 | Leaf types, model info, class labels (alphabetical order), helpers |
| 5 | `test/unit/model_integrity_test.dart` | 4 | SHA-256 correctness, consistency, uniqueness |
| 6 | `test/unit/prediction_test.dart` | 4 | fromMap/toMap, round-trip, null optional fields |
| 7 | `test/dao/dao_test.dart` | 17 | PredictionDao (8), PreferenceDao (5), ModelDao (4), SyncQueue (4) |
| 8 | `test/provider/settings_provider_test.dart` | 4 | loadAll, setValue, themeModeProvider system/dark |
| 9 | `test/provider/history_provider_test.dart` | 9 | State management, filters, copyWith, clearConfidenceFilter |
| 10 | `test/widget_test.dart` | 4 | HomeScreen renders title, scan button, bottom navigation, all leaf types |
| 11 | `test/integration/ota_model_test.dart` | 15 | OTA version rotation (5), model integrity (4), sync queue (4), full OTA flow (2) |

**Tong: 89 tests, tat ca PASS**

### 17.3 Luu y ky thuat
- Widget tests dung `_TestableHomeBody` lightweight widget thay vi full `HomeScreen` vi IndexedStack render HistoryScreen + SettingsScreen co heavy async operations
- DAO tests dung `databaseFactoryFfiNoIsolate` (cung isolate) de tranh SQLite locking
- Provider tests tao `ProviderContainer` rieng cho moi test, dispose qua `addTearDown`

---

*Last updated: 2026-04-02*
*Pipeline verified: Tomato (87.2% Top-1) + Burmese Grape Leaf (87.3% Top-1)*
*Test suite: 89/89 tests passing, flutter analyze 0 issues*
*All 10 implementation steps completed*
*Release APK: 84.2 MB (fat) / 31.3 MB (arm64-v8a)*
