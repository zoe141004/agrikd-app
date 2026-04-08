# Admin Dashboard User Manual

## Overview

The AgriKD Admin Dashboard is a single-page application built with
**React 18**, **Vite 5**, **Supabase JS**, and **Sentry** (error tracking).
It provides project administrators with a centralized interface for monitoring
predictions, managing models and users, and controlling the MLOps pipeline.
The dashboard is deployed on **Vercel** and communicates directly with the
Supabase backend.

Security headers (`X-Frame-Options`, `X-Content-Type-Options`,
`Referrer-Policy`, `Strict-Transport-Security`, `Content-Security-Policy`)
are configured in `vercel.json` for production. The Vite dev server mirrors
a subset of these headers for local development.

The application consists of ten pages, each described in detail below.

---

## Authentication and Access Control

The dashboard uses **Supabase Auth** with email/password credentials.

- Only users whose `profiles` row contains `role = 'admin'` are granted
  access.
- Non-admin users who attempt to log in are shown an **"Access Denied"**
  message and cannot proceed past the login gate.
- Sessions are managed through Supabase's built-in token refresh mechanism.
- Row Level Security (RLS) is enforced on all database tables. Run
  `database/verify_rls_policies.sql` in the Supabase SQL Editor to audit
  all policies.

### Granting Admin Access

Run the following SQL statement in the Supabase SQL Editor or via the
CLI:

```sql
UPDATE profiles SET role = 'admin' WHERE email = 'your@email.com';
```

Replace `your@email.com` with the target user's registered email address.

---

## Pages Guide

### Dashboard (`/`)

The landing page provides a high-level snapshot of the system:

- **Stats cards** -- Total predictions processed, number of active models,
  and registered user count.
- **Area chart** -- Prediction volume over the last 30 days, rendered with Recharts.
- **Leaf type split** -- Horizontal progress bars showing distribution of predictions by leaf type.

### Predictions (`/predictions`)

A paginated table of all prediction records submitted by mobile app users.

| Feature | Description |
|---------|-------------|
| Search | Free-text search across prediction metadata |
| Filter by leaf type | Narrow results to Tomato or Burmese Grape Leaf |
| Filter by date | Select a date range to scope results |
| CSV export | Download the current filtered view as a `.csv` file |

### Models (`/models`)

The model registry and pipeline control center with five tabs:

- **Registry** -- Lists all model versions with status (staging/active/backup),
  format, size, and SHA-256 checksums. Admin can promote staging models to
  active or archive old versions. Max 2 active versions per leaf type.
- **Benchmarks** -- View detailed benchmark results: accuracy, precision,
  recall, F1, latency, model size, and FLOPs per format.
- **Upload Model** -- Upload `.pth` student checkpoints to Supabase Storage.
- **Validate** -- Trigger the GitHub Actions model-pipeline workflow and track
  progress in real-time via Supabase Realtime (pipeline_runs table).
- **OTA Deploy** -- Configure and trigger over-the-air model deployment to
  mobile apps via the model registry status lifecycle.

### Users (`/users`)

User administration panel.

- View the complete list of registered users.
- Change a user's role between `user` and `admin`.
- Activate or deactivate user accounts.

### Data Management (`/data`)

Interface for dataset lifecycle operations powered by DVC. Datasets are
pushed directly to DVC (Google Drive) — Supabase only stores metadata
via the `dvc_operations` database table.

Five tabs:

- **Overview** -- DVC dataset listing, storage usage, and a summary of
  the 5 most recent DVC operations.
- **Stage Data** -- Two methods for staging new datasets:
  - *From Predictions* -- export prediction images above a confidence
    threshold as a staging dataset.
  - *External Source* -- supply a Google Drive or Kaggle URL to download
    and stage a dataset ZIP.
  Staged datasets appear with metadata (file count, classes, size) and
  can be reviewed before pushing to DVC.
- **DVC Operations** -- Full history table of all DVC operations (stage,
  push, pull, export) with status badges, GitHub Actions links, and
  action buttons. DVC Pull/Verify and Push All controls trigger
  GitHub Actions workflows against the DVC remote (Google Drive).
- **Prediction Data** -- Browse prediction statistics, export CSV/JSON,
  and import CSV (collapsed by default).
- **Storage Files** -- Two sub-tabs:
  - *Datasets* -- Browse the `datasets` Supabase Storage bucket
    with download and delete capabilities.
  - *Prediction Images* -- Query the `predictions` table for rows with
    uploaded images. Thumbnails use signed URLs (private
    `prediction-images` bucket, 1-hour expiry). Features: leaf type
    filter, 20-per-page pagination, inline label editing (click label →
    edit → save), and full-size image preview modal.

Operation tracking uses Supabase Realtime subscriptions on the
`dvc_operations` table with GitHub Actions polling as a fallback, so
status persists across page refreshes.

### Releases (`/releases`)

Integration with GitHub Releases.

- Browse the full release history with version tags and changelogs.
- Download APK artifacts directly from each release entry.

### System Health (`/health`)

Operational status overview.

- **Supabase status** -- Connection health and API latency.
- **Database statistics** -- Row counts and table sizes.
- **Storage buckets** -- Number of Supabase Storage buckets detected.

### Settings (`/settings`)

Application-level configuration with six tabs: **General**, **Integrations**,
**Admin**, **CI/CD**, **Deployment**, and **Audit Log**.

- **General** -- View and update general app configuration values. Display
  the current Supabase connection details (project URL and anonymous key).
- **Integrations** -- Configure GitHub repository owner, repo name,
  branch, and Personal Access Token (PAT). Token is stored in
  `localStorage` (persists across sessions). Required for DVC sync,
  model validation, and CI/CD triggers.
- **Admin** -- Admin-specific settings and user management shortcuts.
- **CI/CD** -- Quick-trigger buttons for common CI/CD workflows.
- **Deployment** -- Trigger Vercel deployments and view deployment status.
- **Audit Log** -- View recent audit log entries for admin actions.

---

## Deployment

### Vercel (Recommended)

1. Connect the GitHub repository to a new Vercel project.
2. Set the **Root Directory** to `admin-dashboard`.
3. Add the following environment variables in the Vercel project settings:

   | Variable | Value |
   |----------|-------|
   | `VITE_SUPABASE_URL` | Your Supabase project URL |
   | `VITE_SUPABASE_ANON_KEY` | Your Supabase anonymous key |
   | `VITE_SENTRY_DSN` | Sentry DSN for error tracking (optional) |

4. Deploy. Vercel will automatically build and serve the Vite application.

**Security headers for production:** The file `vercel.json` in
`admin-dashboard/` ships with the following headers pre-configured:

```json
{
  "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }],
  "headers": [
    {
      "source": "/(.*)",
      "headers": [
        { "key": "X-Frame-Options", "value": "DENY" },
        { "key": "X-Content-Type-Options", "value": "nosniff" },
        { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" },
        { "key": "Strict-Transport-Security", "value": "max-age=63072000; includeSubDomains; preload" },
        { "key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=()" },
        { "key": "Content-Security-Policy", "value": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' data: blob: https://*.supabase.co; connect-src 'self' https://*.supabase.co wss://*.supabase.co https://api.github.com https://*.sentry.io; font-src 'self' https://fonts.gstatic.com;" }
      ]
    }
  ]
}
```

| Header | Purpose |
|--------|---------|
| `X-Frame-Options: DENY` | Prevents the dashboard from being embedded in iframes (clickjacking protection) |
| `X-Content-Type-Options: nosniff` | Stops browsers from MIME-sniffing the response away from the declared content type |
| `Referrer-Policy` | Sends the origin only on cross-origin requests; full URL on same-origin |
| `Strict-Transport-Security` | Enforces HTTPS for 2 years with subdomains and preload eligibility |
| `Permissions-Policy` | Disables camera, microphone, and geolocation APIs |
| `Content-Security-Policy` | Restricts resource loading to `self`, Supabase (REST + WebSocket), GitHub API, Sentry, and Google Fonts |

### Manual Trigger

A deployment can also be triggered through the **deploy.yml** GitHub Actions
workflow, which calls the Vercel Deploy Hook configured in the repository
secrets (`VERCEL_DEPLOY_HOOK`).

---

## Local Development

```bash
cd admin-dashboard
npm install
npm run dev
```

The `predev` npm hook automatically runs `sync_env.py` to generate a local
`.env` file from the root `.env`, so there is no need to manually copy
environment variables into the sub-project. The synced variables include:

| Root `.env` Variable | Generated as |
|---------------------|-------------|
| `SUPABASE_URL` | `VITE_SUPABASE_URL` |
| `SUPABASE_ANON_KEY` | `VITE_SUPABASE_ANON_KEY` |
| `SENTRY_DSN` | `VITE_SENTRY_DSN` |

The development server starts at `http://localhost:3000` by default.

---

## Error Tracking

The dashboard uses **Sentry** for automatic error tracking and performance
monitoring. Sentry is initialized conditionally: if `VITE_SENTRY_DSN` is
set, errors and unhandled exceptions are reported automatically. If the
variable is empty or missing, the app runs normally without Sentry.

The React app is wrapped in `<Sentry.ErrorBoundary>`, which catches
rendering errors and displays a fallback message instead of a blank page.

---

## CI/CD Secrets

The following GitHub secrets are used by admin dashboard workflows:

| Secret | Used By |
|--------|---------|
| `SUPABASE_URL` | `deploy.yml` (Vercel env var) |
| `SUPABASE_ANON_KEY` | `deploy.yml` (Vercel env var) |
| `SENTRY_DSN` | `deploy.yml` (mapped to `VITE_SENTRY_DSN`) |
| `VERCEL_DEPLOY_HOOK` | `deploy.yml` (webhook trigger) |

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|--------------|------------|
| "Access Denied" after login | User lacks admin role | Run the `UPDATE profiles` SQL statement above |
| Dashboard shows no data | Supabase environment variables missing | Verify `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` are set |
| Pipeline trigger fails | GitHub token or workflow permissions | Check repository Actions settings and secrets |
| CSV export is empty | Active filters exclude all records | Clear filters and retry |
| Blank page with console errors | JavaScript crash not caught | Check Sentry dashboard for error details, or browser DevTools |
