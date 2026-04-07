# CI/CD Setup Guide

## Prerequisites

- GitHub repository with the AgriKD monorepo
- Supabase project (see [Supabase Setup Guide](supabase_setup.md))
- Google Drive service account for DVC (for model/data workflows)
- Vercel account (optional, for admin dashboard deployment)

## 1. Required GitHub Secrets

Go to **Repository → Settings → Secrets and variables → Actions** and add:

| Secret | Required By | How to Get |
|--------|-------------|------------|
| `SUPABASE_URL` | CI, Release, Model Pipeline, Export Data | Supabase Dashboard → Settings → API → URL |
| `SUPABASE_ANON_KEY` | CI, Release | Supabase Dashboard → Settings → API → anon key |
| `SUPABASE_SERVICE_ROLE_KEY` | Model Pipeline, Export Data, Dataset Upload | Supabase Dashboard → Settings → API → service_role key |
| `SENTRY_DSN` | CI, Release | sentry.io → Project → Settings → Client Keys |
| `GOOGLE_WEB_CLIENT_ID` | CI, Release | Google Cloud Console → Credentials → OAuth Client ID |
| `GDRIVE_CREDENTIALS_DATA` | DVC Pull/Push, Train, Validate, Export, Dataset Upload | Base64-encoded Google Drive service account JSON |
| `VERCEL_DEPLOY_HOOK` | Deploy (optional) | Vercel → Project → Settings → Git → Deploy Hooks |

### Create DVC credentials:
```bash
# 1. Create a service account in Google Cloud Console
# 2. Download the JSON key file
# 3. Base64-encode it:
base64 -w 0 service-account.json
# 4. Paste the output as GDRIVE_CREDENTIALS_DATA secret
```

## 2. Workflows Overview

### Automatic workflows (triggered by push/PR):

| Workflow | File | Trigger | Purpose |
|----------|------|---------|---------|
| **CI** | `ci.yml` | Push to `main`/`release/*`, PRs to `main` | Lint, test, build APK |
| **Release** | `release.yml` | Push tag `v*` | Build APK + create GitHub Release |

### Manual workflows (workflow_dispatch):

| Workflow | File | Purpose |
|----------|------|---------|
| **Train** | `train.yml` | Run full training pipeline |
| **Validate Model** | `validate-model.yml` | Validate + benchmark a specific model |
| **Model Pipeline** | `model-pipeline.yml` | Full conversion + benchmark + upload to Supabase |
| **DVC Pull** | `dvc-pull.yml` | Pull datasets from Google Drive |
| **DVC Push** | `dvc-push.yml` | Push datasets to Google Drive |
| **Export Data** | `export-data.yml` | Export predictions from Supabase |
| **Dataset Upload** | `dataset-upload.yml` | Add new dataset from GDrive or predictions |
| **Deploy** | `deploy.yml` | Trigger Vercel deployment for admin dashboard |
| **Model Rollback** | `model-rollback.yml` | Rollback model version in registry |

## 3. CI Workflow (`ci.yml`)

Runs on every push to `main` or PR. 5 stages:

```
Lint & Format → Flutter Tests → Build APK
                              ↘ Model Conversion → Model Validation
```

| Stage | What it does |
|-------|-------------|
| **Lint** | `dart format --set-exit-if-changed .` + `flutter analyze` |
| **Tests** | `flutter test --exclude-tags=widget` |
| **Build APK** | Release APK with obfuscation + `--dart-define` secrets |
| **Model Conversion** | Only runs if commit contains `[model]` or `mlops_pipeline/` files changed |
| **Model Validation** | Validates + evaluates converted models |

**Flutter version:** 3.41.4
**Python version:** 3.10

## 4. Release Workflow (`release.yml`)

Triggered by pushing a version tag:

```bash
# Create a release:
git tag v1.0.0
git push origin v1.0.0

# Create a pre-release:
git tag v1.0.0-rc1
git push origin v1.0.0-rc1
```

The workflow:
1. Runs tests
2. Builds release APK (with obfuscation + dart-define)
3. Creates GitHub Release with APK attached
4. Pre-release tags (`-rc`, `-beta`) are automatically marked

**Artifacts:**
- `app-release.apk` — attached to the GitHub Release
- `debug-symbols` — uploaded as workflow artifact (90-day retention)

## 5. Model Pipeline (`model-pipeline.yml`)

Full MLOps pipeline triggered manually with inputs:
- `leaf_type`: tomato or burmese_grape_leaf
- `version`: semantic version (e.g., 1.2.0)
- `model_url`: Supabase Storage URL of the .pth checkpoint

Steps:
1. Download checkpoint from Supabase Storage
2. Convert PTH → ONNX → TFLite (float16 + float32)
3. Validate cross-format consistency
4. Evaluate on test dataset (quality gate: configurable min accuracy)
5. Compute SHA-256 hashes
6. Upload TFLite model + benchmark results to Supabase
7. Update pipeline_runs table status (converting → evaluating → completed/failed)

## 6. DVC Workflows

All DVC workflows support an optional `dvc_operation_id` input. When
provided, the workflow reports its progress back to the `dvc_operations`
Supabase table (status transitions: pending → running → completed/failed)
with `github_run_id` and `github_run_url` for traceability.

### Pull data (`dvc-pull.yml`):
```
Manual trigger → Select leaf_type (optional) → Pull from Google Drive
```
Uses 3 retries with 10s backoff.

### Push data (`dvc-push.yml`):
```
Manual trigger → Push all DVC-tracked data to Google Drive
```

### Dataset Upload (`dataset-upload.yml`):
Three source modes plus staging support:
- **gdrive**: Download ZIP from Google Drive URL → prepare dataset
- **kaggle**: Download dataset from Kaggle → prepare dataset
- **predictions**: Export predictions from Supabase (with confidence filter) → prepare dataset

Additional inputs:
- `stage_only` (default `'false'`): When `'true'`, stages the dataset to
  Supabase Storage instead of pushing to DVC. Uses
  `.github/scripts/stage_dataset_to_storage.py` to collect metadata and
  upload a ZIP to the `datasets/{leaf_type}/staging/` path.
- `dvc_operation_id`: Links the workflow run to a `dvc_operations` row
  for real-time status tracking from the admin dashboard.

## 7. Export Data (`export-data.yml`)

Manually triggered. Exports all predictions (paginated, 1000/page) from Supabase, saves to `data/exports/predictions_snapshot.json`, then tracks with DVC and pushes to Google Drive.

**PII filtering:** Export excludes sensitive fields from the prediction data.

Supports `dvc_operation_id` for status report-back.

## 8. Admin Dashboard Deploy (`deploy.yml`)

Manually triggered. Sends a POST request to the Vercel Deploy Hook URL to trigger a fresh deployment.

Alternatively, connect the `admin-dashboard/` directory to Vercel for automatic deploys on push.

## 9. Self-Hosted Runner (Optional)

For Jetson-specific workflows or GPU training:

```bash
# On the Jetson or GPU machine:
# 1. Download the runner from GitHub → Settings → Actions → Runners → New self-hosted runner
# 2. Configure and start:
./config.sh --url https://github.com/<owner>/<repo> --token <token>
./run.sh
```

Then target it in workflows with `runs-on: self-hosted`.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| CI fails on `dart format` | Run `dart format .` locally and commit |
| DVC pull fails | Check `GDRIVE_CREDENTIALS_DATA` secret and Google Drive sharing permissions |
| APK build fails on secrets | Ensure all 4 secrets are set: SUPABASE_URL, SUPABASE_ANON_KEY, SENTRY_DSN, GOOGLE_WEB_CLIENT_ID |
| Model conversion not running | Commit message must contain `[model]` or change files in `mlops_pipeline/` |
| Release not created | Tag must match `v*` pattern (e.g., `v1.0.0`) |
| Export data fails | Check `SUPABASE_SERVICE_ROLE_KEY` secret |
