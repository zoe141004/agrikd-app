# AgriKD Documentation

## Technical Reference

Architecture, methods, techniques, and specifications.

| Document | Description |
|----------|-------------|
| [project_context.md](technical/project_context.md) | System architecture, technology stack, data flow diagrams, CI/CD workflow map, database schemas, class mappings |
| [project_instruction.md](technical/project_instruction.md) | Master specification — model architecture, preprocessing pipeline, Flutter app architecture, security, TFLite integration, online/offline behavior |
| [build_plan.md](technical/build_plan.md) | Flutter app implementation log — gap analysis, 5 phases (A-E), step-by-step build journal, production readiness assessment |

## Setup & Build Guides

Step-by-step instructions for setup, build, and deployment.

| Guide | Description |
|-------|-------------|
| [flutter_app_build.md](guides/flutter_app_build.md) | Flutter app — prerequisites, env config, debug/release builds, signing, APK variants, TFLite bundling |
| [supabase_setup.md](guides/supabase_setup.md) | Supabase project — create project, Auth, run migration SQL (001-005), verify RLS, set admin, storage buckets |
| [mlops_pipeline_setup.md](guides/mlops_pipeline_setup.md) | MLOps pipeline — Python venv, DVC, config files, run pipeline, individual scripts, adding new datasets |
| [cicd_setup.md](guides/cicd_setup.md) | CI/CD — GitHub Secrets, all 10 workflows (CI, Release, Train, Model Pipeline, DVC, Deploy, etc.) |
| [admin_dashboard_manual.md](guides/admin_dashboard_manual.md) | Admin Dashboard — deployment (Vercel), local dev, page-by-page usage guide, troubleshooting |
| [jetson_deployment_guide.md](guides/jetson_deployment_guide.md) | Jetson Edge — setup script, GUI app, REST API, Docker, TensorRT, monitoring, troubleshooting |
| [product_release.md](guides/product_release.md) | End-user guide — APK download, installation, quick start, settings, OTA updates, FAQ |
