# Flutter App Build Guide

## Prerequisites

- Flutter SDK 3.41.4+ (includes Dart SDK ^3.11.1) ([install](https://docs.flutter.dev/get-started/install))
- Android Studio (for Android SDK and emulator)
- JDK 17 (bundled with Android Studio or install Zulu JDK)
- Git

Verify installation:
```bash
flutter doctor
```

## 1. Clone and Setup

```bash
cd <project-root>/mobile_app
flutter pub get
```

## 2. Environment Configuration

### Option A: Local development (using .env file)

1. Create root `.env` from template:
   ```bash
   cd <project-root>
   cp .env.example .env
   # Edit .env with your actual values
   ```

2. Run the sync script to distribute env vars:
   ```bash
   python sync_env.py
   ```
   This generates `mobile_app/.env` with only safe keys:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `GOOGLE_WEB_CLIENT_ID`
   - `SENTRY_DSN`

   **Note:** `SUPABASE_SERVICE_ROLE_KEY` is intentionally excluded from mobile builds.

### Option B: CI/CD builds (using --dart-define)

Values are injected at build time — no `.env` file needed:
```bash
flutter build apk --release \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_ANON_KEY=... \
  --dart-define=SENTRY_DSN=... \
  --dart-define=GOOGLE_WEB_CLIENT_ID=...
```

## 3. Run in Debug Mode

```bash
cd <project-root>/mobile_app

# On connected device or emulator:
flutter run

# On Chrome (web):
flutter run -d chrome
```

## 4. Run Tests

```bash
# Unit + provider + DAO tests (recommended):
flutter test test/unit/ test/provider/ test/dao/

# All tests except widget tests:
flutter test --exclude-tags=widget

# All tests (widget tests may hang without Supabase mock):
flutter test
```

Current test count: **89 tests** across 11 test files:
- `test/unit/` — Prediction model, image preprocessor, model constants, model integrity, app strings, app constants
- `test/provider/` — History provider, settings provider
- `test/dao/` — PredictionDao, PreferenceDao, ModelDao, SyncQueue
- `test/integration/` — OTA model version rotation, model integrity, sync queue, full OTA flow
- `test/widget_test.dart` — Home screen rendering, navigation, scan button, leaf types

## 5. Build Release APK

### Standard release build:
```bash
cd <project-root>/mobile_app

flutter build apk --release \
  --obfuscate \
  --split-debug-info=build/debug-info \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=GOOGLE_WEB_CLIENT_ID=$GOOGLE_WEB_CLIENT_ID
```

### Per-ABI split builds (smaller APK):
```bash
flutter build apk --release --split-per-abi \
  --obfuscate \
  --split-debug-info=build/debug-info \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY \
  --dart-define=SENTRY_DSN=$SENTRY_DSN \
  --dart-define=GOOGLE_WEB_CLIENT_ID=$GOOGLE_WEB_CLIENT_ID
```

### APK output sizes:
| Variant | Size |
|---------|------|
| Fat APK (all ABIs) | ~84.2 MB |
| arm64-v8a only | ~31.3 MB |

Output location: `build/app/outputs/flutter-apk/`

## 6. Signing for Production

1. Generate a keystore:
   ```bash
   keytool -genkey -v -keystore agrikd-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias agrikd
   ```

2. Create `mobile_app/android/key.properties`:
   ```properties
   storeFile=<path-to>/agrikd-release.jks
   storePassword=<your-store-password>
   keyAlias=agrikd
   keyPassword=<your-key-password>
   ```

3. The `build.gradle.kts` already has R8 minification and ProGuard configured:
   - `minSdk = 24` (Android 7.0)
   - `targetSdk = 34` (Android 14)
   - `isMinifyEnabled = true`
   - `isShrinkResources = true`

## 7. TFLite Model Bundling

Models are bundled as Flutter assets at:
```
mobile_app/assets/models/
├── tomato/
│   └── tomato_student.tflite          (~0.95 MB)
└── burmese_grape_leaf/
    └── burmese_grape_leaf_student.tflite  (~0.95 MB)
```

Registered in `pubspec.yaml`:
```yaml
assets:
  - assets/models/tomato/tomato_student.tflite
  - assets/models/burmese_grape_leaf/burmese_grape_leaf_student.tflite
```

Delegate fallback order: GPU → XNNPack → CPU

## 8. Deep Link Configuration

The app uses PKCE auth flow with deep link callback:
- **Scheme:** `com.agrikd.app://callback`
- **Android:** Configured in `AndroidManifest.xml` under `<intent-filter>`
- **Supabase:** Must add `com.agrikd.app://callback` to:
  - Dashboard → Authentication → URL Configuration → Redirect URLs
  - Dashboard → Authentication → URL Configuration → Site URL

## 9. Create a Release via Git Tag

```bash
git tag v1.0.0
git push origin v1.0.0
```

This triggers the `release.yml` workflow which:
1. Runs tests
2. Builds the release APK
3. Creates a GitHub Release with the APK attached
4. Tags with `-rc` or `-beta` are marked as prerelease

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `sqlite3.dll` PathExistsException on Windows | Delete `build/native_assets/` and retry |
| Widget tests hang | Known issue — use `--exclude-tags=widget` or run unit tests only |
| `.env` not found | Run `python sync_env.py` from project root |
| Google Sign-In fails | Ensure `GOOGLE_WEB_CLIENT_ID` is set (in .env or --dart-define) |
| Supabase connection fails | Check `SUPABASE_URL` and `SUPABASE_ANON_KEY` values |
| `flutter analyze` warnings | Run `dart format .` then `flutter analyze` |
