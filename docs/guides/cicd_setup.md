# CI/CD Setup Guide

## Prerequisites

- GitHub repository with the AgriKD monorepo
- Supabase project (see [Supabase Setup Guide](supabase_setup.md))
- Google Cloud Storage (GCS) service account for DVC (for model/data workflows)
- Vercel account (optional, for admin dashboard deployment)

## 1. Required GitHub Secrets

Go to **Repository → Settings → Secrets and variables → Actions** and add:

| Secret | Required By | How to Get |
|--------|-------------|------------|
| `SUPABASE_URL` | CI, Release, Model Pipeline, Export Data, DVC Pull/Push, Dataset Upload/Delete, Deploy | Supabase Dashboard → Settings → API → URL |
| `SUPABASE_ANON_KEY` | CI, Release | Supabase Dashboard → Settings → API → anon key |
| `SUPABASE_SERVICE_ROLE_KEY` | Model Pipeline, Export Data, Dataset Upload/Delete, DVC Pull/Push, Model Rollback | Supabase Dashboard → Settings → API → service_role key |
| `SENTRY_DSN` | CI, Release | sentry.io → Project → Settings → Client Keys |
| `GOOGLE_WEB_CLIENT_ID` | CI, Release | Google Cloud Console → Credentials → OAuth Client ID |
| `GOOGLE_APPLICATION_CREDENTIALS_DATA` | DVC Pull/Push, Train, Validate, Export, Dataset Upload, Dataset Delete | GCS service account JSON |
| `VERCEL_DEPLOY_HOOK` | Deploy (optional) | Vercel → Project → Settings → Git → Deploy Hooks |
| `KAGGLE_USERNAME` | Dataset Upload (kaggle source, optional) | kaggle.com → Settings → API → Username |
| `KAGGLE_KEY` | Dataset Upload (kaggle source, optional) | kaggle.com → Settings → API → Create New Token |

> **Note:** `GITHUB_TOKEN` is automatically provided by GitHub Actions — no manual setup needed.

### Create DVC credentials:
```bash
# 1. Create a service account in Google Cloud Console
# 2. Download the JSON key file
# 3. Base64-encode it:

# Linux / macOS:
base64 -w 0 service-account.json

# Windows (PowerShell):
[Convert]::ToBase64String([IO.File]::ReadAllBytes("service-account.json"))

# 4. Paste the output as GOOGLE_APPLICATION_CREDENTIALS_DATA secret
```

## 2. Workflows Overview

13 workflows total: 3 automatic + 10 manual.

### Automatic workflows (triggered by push/PR):

| Workflow | File | Trigger | Purpose |
|----------|------|---------|---------|
| **CI** | `ci.yml` | Push to `main`/`develop`/`release/*`, PRs to `main`/`develop`/`feature/**` | Lint, test, build APK, dashboard tests |
| **Release** | `release.yml` | Push tag `v*` | Build APK + create GitHub Release |
| **CodeQL** | `codeql.yml` | Push to `main`, PRs to `main`, weekly schedule | Security scanning (JS/TS + Python) |

### Manual workflows (workflow_dispatch):

| Workflow | File | Purpose |
|----------|------|---------|
| **Train** | `train.yml` | Run full training pipeline |
| **Validate Model** | `validate-model.yml` | Validate + benchmark a specific model |
| **Model Pipeline** | `model-pipeline.yml` | Full conversion + benchmark + upload to Supabase |
| **DVC Pull** | `dvc-pull.yml` | Pull datasets from GCS (Google Cloud Storage) |
| **DVC Push** | `dvc-push.yml` | Push datasets to GCS |
| **Export Data** | `export-data.yml` | Export predictions from Supabase |
| **Dataset Upload** | `dataset-upload.yml` | Add new dataset from GDrive, Kaggle, or predictions → push directly to DVC |
| **Dataset Delete** | `dataset-delete.yml` | Delete dataset from DVC tracking + garbage-collect from GCS remote |
| **Deploy** | `deploy.yml` | Trigger Vercel deployment for admin dashboard |
| **Model Rollback** | `model-rollback.yml` | Rollback model version in registry |

## 3. CI Workflow (`ci.yml`)

Runs on every push to `main`/`develop`/`release/*` or PR to `main`/`develop`/`feature/**`. 6 jobs:

```
Dependency Audit → Lint & Format → Flutter Tests → Build APK
                                   Dashboard Tests → Jetson Python Lint
```

| Stage | What it does |
|-------|-------------|
| **Dependency Audit** | `npm audit` + `pip audit` for known vulnerabilities |
| **Lint** | `dart format --set-exit-if-changed .` + `flutter analyze` |
| **Tests** | `flutter test --exclude-tags=widget` (144 tests) |
| **Build APK** | Release APK with obfuscation + `--dart-define` secrets |
| **Dashboard Tests** | `vitest run` — admin dashboard unit/integration tests (113 tests) |
| **Jetson Python Lint** | `ruff check` on Jetson Python code |

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
- `min_accuracy` (optional, default: 80): Minimum accuracy threshold (%) for quality gate
- `pipeline_run_id` (optional): Pipeline run ID for status tracking (from pipeline_runs table)
- `fold` (optional): CV fold number (1-5) for StratifiedKFold test set. If empty, uses standard 70/10/20 split.

Steps:
1. Download checkpoint from Supabase Storage
2. Convert PTH → ONNX → TFLite (float16 + float32)
3. Validate cross-format consistency
4. Evaluate on test dataset (quality gate: configurable min accuracy)
   - Standard mode: Stratified split 70% train / 10% val / 20% test (seed=42)
   - Fold mode: StratifiedKFold(5), fold N as test set (~20%), matching CV research setup
5. Compute SHA-256 hashes
6. Upload TFLite model + benchmark results to Supabase
7. **Auto-activate**: If fewer than 2 active models exist for the leaf_type, the new model is promoted to `active` **before** archiving existing active models to `model_versions`. This activate-first order prevents a window where no model is active if a network failure interrupts the process.
8. Update pipeline_runs table status (converting → evaluating → completed/failed)

**Fold-aware versioning:** When a fold is specified in the Dashboard, the version is
suffixed with `-foldN` (e.g., `1.2.0-fold5`). The Jetson edge device parses this
suffix and uses the same StratifiedKFold split for on-device TensorRT evaluation.

## 6. DVC Workflows

All DVC workflows support an optional `dvc_operation_id` input. When
provided, the workflow reports its progress back to the `dvc_operations`
Supabase table (status transitions: pending → running → completed/failed)
with `github_run_id` and `github_run_url` for traceability.

### Pull data (`dvc-pull.yml`):
```
Manual trigger → Select leaf_type (optional) → Pull from GCS
```
Uses 3 retries with 10s backoff.

### Push data (`dvc-push.yml`):
```
Manual trigger → Push all DVC-tracked data to GCS
```
Pushes local tracked data directly (`dvc push -v`) — no prior `dvc pull` required, which avoids unnecessary disk usage on GitHub runners at scale.

### Dataset Upload (`dataset-upload.yml`):
Three source modes — datasets are pushed directly to DVC (GCS), not staged in Supabase Storage:
- **gdrive**: Download ZIP from Google Drive URL → prepare dataset → push to DVC (GCS)
- **kaggle**: Download dataset from Kaggle → prepare dataset → push to DVC (requires `KAGGLE_USERNAME` + `KAGGLE_KEY` secrets)
- **predictions**: Export predictions from Supabase (with confidence filter) → prepare dataset → push to DVC

Git push uses 3 retries with `git pull --rebase` between attempts.

Additional inputs:
- `dvc_operation_id`: Links the workflow run to a `dvc_operations` row
  for real-time status tracking from the admin dashboard.

## 7. Export Data (`export-data.yml`)

Manually triggered. Exports all predictions (paginated, 1000/page) from Supabase, saves to `data/exports/predictions_snapshot.json`, then tracks with DVC and pushes to GCS.

**PII filtering:** Export excludes sensitive fields from the prediction data.

**Security:** Supabase credentials are scoped to individual steps (step-level env), not job-level.

Supports `dvc_operation_id` for status report-back.

## 8. Dataset Delete (`dataset-delete.yml`)

Manually triggered (from admin dashboard or GitHub Actions). Removes a dataset from DVC tracking and cleans up the GCS remote:

```
Trigger → dvc remove dvc/data_<leaf_type>.dvc → dvc gc --cloud → git commit+push → Supabase status update
```

- Removes the `.dvc` file from Git tracking (if present)
- Always runs `dvc gc --cloud --workspace -f` to garbage-collect unreferenced data from GCS (handles both first-time and re-delete scenarios)
- Cleans up the local `data/<leaf_type>/` directory
- Reports status back to `dvc_operations` table (requires `SUPABASE_SERVICE_ROLE_KEY`)
- The admin dashboard triggers this workflow and waits for completion before cleaning DB records
- All GitHub Actions are pinned to SHA commit hashes for supply chain security

**Required migration:** `database/migrations/017_dataset_delete.sql` (adds `'delete'` operation and `'deleting'` status).

## 9. Model Rollback (`model-rollback.yml`)

Manually triggered. Rolls back a model version in the registry:

- Sets the target version's status back to `staging`
- Restores the previous active version (if any)
- Updates model registry metadata
- Reports status to audit log

Inputs: `leaf_type` (free text, supports any leaf type), `version`, `reason`.

## 10. Admin Dashboard Deploy (`deploy.yml`)

Manually triggered. Sends a POST request to the Vercel Deploy Hook URL to trigger a fresh deployment. Uses concurrency group to prevent overlapping deploys.

Alternatively, connect the `admin-dashboard/` directory to Vercel for automatic deploys on push.

## 11. Self-Hosted Runner (Optional)

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
| DVC pull fails | Check `GOOGLE_APPLICATION_CREDENTIALS_DATA` secret and GCS bucket IAM permissions |
| APK build fails on secrets | Ensure all 4 secrets are set: SUPABASE_URL, SUPABASE_ANON_KEY, SENTRY_DSN, GOOGLE_WEB_CLIENT_ID |
| Model conversion not running | Commit message must contain `[model]` or change files in `mlops_pipeline/` |
| Release not created | Tag must match `v*` pattern (e.g., `v1.0.0`) |
| Export data fails | Check `SUPABASE_SERVICE_ROLE_KEY` secret |
