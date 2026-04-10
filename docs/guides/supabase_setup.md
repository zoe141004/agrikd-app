# Supabase Database Setup Guide

## 1. Create a Supabase Project

1. Go to [supabase.com](https://supabase.com) and create a new project
2. Note down your:
   - **Project URL** (`https://<project-ref>.supabase.co`)
   - **Anon Key** (public, safe for client apps)
   - **Service Role Key** (private, for server-side operations only)

## 2. Configure Authentication

### Email Auth (enabled by default)

Dashboard → Authentication → Providers:
- Email: **Enabled**
- Confirm email: Enabled (recommended for production)

### Google OAuth

1. Create OAuth credentials in [Google Cloud Console](https://console.cloud.google.com/apis/credentials):
   - Application type: **Web application**
   - Authorized redirect URIs: `https://<project-ref>.supabase.co/auth/v1/callback`
2. Dashboard → Authentication → Providers → Google:
   - Client ID: paste from Google Cloud
   - Client Secret: paste from Google Cloud
3. Save your **Web Client ID** — this goes into `GOOGLE_WEB_CLIENT_ID`

### URL Configuration

Dashboard → Authentication → URL Configuration:
- **Site URL:** `com.agrikd.app://callback`
- **Redirect URLs:** Add `com.agrikd.app://callback`

This enables the PKCE auth flow for the Flutter mobile app.

## 3. Run Migration SQL

Open **Dashboard → SQL Editor → New query** and run these files in order:

| Order | File | What it creates |
|-------|------|-----------------|
| 1 | `database/migrations/001_tables.sql` | 6 tables: profiles, predictions, model_registry, audit_log, model_benchmarks, model_versions |
| 2 | `database/migrations/002_functions_triggers.sql` | is_admin_role(), handle_new_user(), sync_model_urls() + triggers + backfill |
| 3 | `database/migrations/003_rls_policies.sql` | RLS policies for all 6 tables |
| 4 | `database/migrations/004_indexes.sql` | 7 performance indexes |
| 5 | `database/migrations/005_storage.sql` | 3 storage buckets + policies |
| 6 | `database/migrations/006_model_reports_and_rpcs.sql` | Model report tables + RPC functions |
| 7 | `database/migrations/007_multi_version.sql` | Multi-version model registry (status lifecycle), enforce_version_lifecycle() trigger, pipeline_runs table |
| 8 | `database/migrations/008_cleanup_and_realtime.sql` | Cleanup deprecated objects + enable Realtime on pipeline_runs |
| 9 | `database/migrations/009_security_hardening.sql` | Security hardening: tighten RLS policies, add missing indexes |
| 10 | `database/migrations/010_fix_lifecycle_for_update.sql` | Fix enforce_version_lifecycle trigger for UPDATE operations |
| 11 | `database/migrations/011_dvc_operations.sql` | DVC operations tracking table (stage/push/pull/export with status lifecycle) |
| 12 | `database/migrations/012_devices.sql` | Device management: provisioning_tokens, devices table with Device Shadow, RLS, config_version trigger, device_id on predictions |
| 13 | `database/migrations/013_model_engines.sql` | ONNX URL columns on model_registry + model_engines table for hardware-specific TensorRT engines |
| 14 | `database/migrations/014_audit_fixes.sql` | Admin-only guards on dashboard RPCs, profiles UPDATE policy for users, model_reports SELECT policy, audit_log user_id index |
| 15 | `database/migrations/015_audit_log_cleanup.sql` | Migrates legacy audit_log schema (BIGINT id, actor_email) to correct UUID-based schema, preserves existing data |

### Migration 012: Device Management
- `provisioning_tokens` table — one-time tokens for Zero-Touch Provisioning
- `devices` table — Jetson device registry with Device Shadow
- RLS policies for admin, user, device self-access via `X-Device-Token` header
- Auto-increment `config_version` trigger
- `device_id` column added to `predictions` table
- File: `database/migrations/012_devices.sql`

All scripts are idempotent (safe to re-run): they use `IF NOT EXISTS`, `DROP IF EXISTS`, and `CREATE OR REPLACE`.

## 4. Verify Setup

Run the verification script:
```sql
-- Paste contents of database/verify_rls_policies.sql into SQL Editor
-- Check Messages/Notices tab for results
```

Expected output: All checks should show `[PASS]`. The script verifies:
- RLS enabled on all required tables (profiles, predictions, model_registry, audit_log, model_benchmarks, model_versions, dvc_operations)
- All policies exist per table
- `is_admin_role()` function exists and is SECURITY DEFINER
- `handle_new_user()` trigger on auth.users
- `enforce_version_lifecycle()` trigger on model_registry (replaces old sync_model_urls)
- Storage buckets exist (models, datasets, prediction-images)
- All indexes exist

> **Note:** The verification script does not yet cover `provisioning_tokens`,
> `devices`, and `model_engines` tables from migrations 012–013. Verify their RLS manually:
> ```sql
> SELECT tablename, policyname FROM pg_policies
> WHERE tablename IN ('provisioning_tokens', 'devices', 'model_engines');
> ```

**Migration 011** auto-enables Realtime for `dvc_operations`. If it fails
due to insufficient privileges, run manually in the SQL Editor:

```sql
ALTER PUBLICATION supabase_realtime ADD TABLE public.dvc_operations;
```

## 5. Set Admin User

After a user signs up (via the Flutter app or Admin Dashboard), promote them to admin:

```sql
UPDATE profiles SET role = 'admin' WHERE email = 'your-admin@email.com';
```

## 6. Storage Buckets

Created automatically by `005_storage.sql`:

| Bucket | Public | Purpose |
|--------|--------|---------|
| `models` | Yes | TFLite model files for OTA download |
| `datasets` | Yes | Training datasets |
| `prediction-images` | No | User-uploaded leaf images (scoped per user) |

Verify in Dashboard → Storage.

> **Note:** The admin dashboard's *Prediction Images* browser reads from the
> private `prediction-images` bucket using signed URLs (`createSignedUrl`
> with 1-hour expiry). Admin users must have read access to this bucket
> (handled automatically via the authenticated Supabase session with
> appropriate RLS policies).

## 7. Environment Variables

After setup, distribute your credentials:

### Root `.env`:
```env
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_ROLE_KEY=eyJ...
GOOGLE_WEB_CLIENT_ID=xxx.apps.googleusercontent.com
SENTRY_DSN=https://xxx@sentry.io/xxx
GDRIVE_CREDENTIALS_DATA=<base64-encoded-service-account-json>
VERCEL_DEPLOY_HOOK=https://api.vercel.com/v1/integrations/deploy/...
KAGGLE_USERNAME=your_kaggle_username
KAGGLE_KEY=your_kaggle_api_key
```

### Sync to sub-projects:
```bash
python sync_env.py
```

This generates:
| Target | File | Keys included |
|--------|------|---------------|
| Flutter app | `mobile_app/.env` | SUPABASE_URL, SUPABASE_ANON_KEY, GOOGLE_WEB_CLIENT_ID, SENTRY_DSN |
| Admin Dashboard | `admin-dashboard/.env` | VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY, VITE_SENTRY_DSN |
| Jetson Edge | `jetson/config/config.json` | supabase_url, supabase_key (in sync block) |

## 8. Database Schema Overview

### Key relationships:
- `profiles.id` → `auth.users.id` (auto-created by `handle_new_user()` trigger)
- `predictions.user_id` → `auth.users.id`
- `model_registry` uses `enforce_version_lifecycle()` BEFORE trigger to enforce max 2 active versions per leaf_type and sync `file_url = model_url` for backward compatibility
- `pipeline_runs` tracks CI/CD pipeline progress with Supabase Realtime
- Flutter reads `model_url` + `sha256_checksum` from `model_registry` (status='active') for OTA updates

### OTA Model Update Flow:
1. Admin uploads .pth checkpoint via Dashboard → triggers GitHub Actions model-pipeline
2. Pipeline converts PTH → ONNX → TFLite, evaluates accuracy, runs quality gate
3. Pipeline uploads TFLite to `models` bucket and upserts `model_registry` with status='staging'
4. Admin promotes model to 'active' via Dashboard (trigger enforces max 2 active)
5. Flutter app reads active models → downloads → verifies SHA-256 → saves locally

## 9. Database Backup Strategy

- **Supabase Free tier:** Daily automatic backups, retained for 7 days
- **Supabase Pro plan:** Point-in-Time Recovery (PITR) with granular restore to any point within the retention window
- **Manual export:** Use `pg_dump` via the Supabase CLI or run export queries in the Dashboard SQL Editor
- **Recommendation:** Always export critical data before running schema migrations

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "relation does not exist" | Run migrations in order: 001 → 002 → ... → 012 |
| "function is_admin_role() does not exist" | Run 002_functions_triggers.sql (creates the function referenced by 003_rls_policies.sql) |
| RLS blocks all queries | Ensure the user has a profile row. Check `handle_new_user()` trigger exists. |
| Storage upload fails | Check bucket policies in 005_storage.sql. Verify bucket exists. |
| Google Sign-In callback fails | Add `com.agrikd.app://callback` to Redirect URLs in Auth settings |
| `verify_rls_policies.sql` shows FAIL | Re-run the relevant migration file for the failing component |
