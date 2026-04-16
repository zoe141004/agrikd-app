# AgriKD Documentation

## Technical Reference

| Document | Description |
|----------|-------------|
| [system_reference.md](technical/system_reference.md) | **Single source of truth** — system architecture, tech stack, data flows, model spec, database schemas, CI/CD, security, class mappings, environment variables |
| [build_plan.md](technical/build_plan.md) | Flutter app implementation log — gap analysis, 5 phases (A-E), step-by-step build journal, production readiness assessment |

## Setup & Build Guides

| Guide | Description |
|-------|-------------|
| [flutter_app_build.md](guides/flutter_app_build.md) | Flutter app — prerequisites, env config, debug/release builds, signing, APK variants, TFLite bundling |
| [supabase_setup.md](guides/supabase_setup.md) | Supabase project — create project, Auth, run migration SQL (001-022), verify RLS, set admin, storage buckets |
| [mlops_pipeline_setup.md](guides/mlops_pipeline_setup.md) | MLOps pipeline — Python venv, DVC, config files, run pipeline, individual scripts, adding new datasets |
| [cicd_setup.md](guides/cicd_setup.md) | CI/CD — GitHub Secrets, all 13 workflows (CI, Release, CodeQL, Train, Model Pipeline, DVC, Dataset Delete, Deploy, etc.) |
| [admin_dashboard_manual.md](guides/admin_dashboard_manual.md) | Admin Dashboard — deployment (Vercel), local dev, page-by-page usage guide, troubleshooting |
| [jetson_deployment_guide.md](guides/jetson_deployment_guide.md) | Jetson Edge — setup script, GUI app, REST API, systemd, TensorRT, monitoring, troubleshooting |
| [product_release.md](guides/product_release.md) | End-user guide — APK download, installation, quick start, settings, OTA updates, FAQ |
