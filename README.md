# AgriKD — Plant Leaf Disease Recognition

AI-powered plant disease detection using Knowledge Distillation (ViT-Base teacher to MobileNetV2 student). Supports **Tomato** (10 classes) and **Burmese Grape Leaf** (5 classes) with offline-first, zero-cost design.

## Components

| Component | Technology | Description |
|-----------|-----------|-------------|
| Mobile App | Flutter + Riverpod + TFLite + Sentry | Offline diagnosis with cloud sync |
| Admin Dashboard | React + Vite + Supabase + Sentry | Management console (models, users, data) |
| MLOps Pipeline | Python + DVC + GitHub Actions | Model conversion & evaluation |
| Jetson Edge | TensorRT + PyQt5 GUI + Flask API | Edge inference with camera & Active Learning |
| Database (IaC) | Supabase PostgreSQL + RLS | Schema, policies & verification scripts |

## Quick Start

```bash
# Windows development setup (recommended)
setup_windows_dev.bat

# Or manual setup
cp .env.example .env              # Edit with your credentials
python sync_env.py                 # Sync env to mobile_app/, admin-dashboard/, jetson/
cd mobile_app && flutter pub get   # Install Flutter dependencies
cd mobile_app && flutter run       # Loads .env via flutter_dotenv
```

## Documentation

All guides are in [`docs/`](docs/README.md):

- [Project Architecture & Overview](docs/technical/project_context.md)
- [Product Release Guide](docs/guides/product_release.md)
- [Supabase Setup](docs/guides/supabase_setup.md)
- [CI/CD Setup](docs/guides/cicd_setup.md)
- [Admin Dashboard Manual](docs/guides/admin_dashboard_manual.md)
- [Jetson Deployment & GUI Guide](docs/guides/jetson_deployment_guide.md)
- [Flutter App Build](docs/guides/flutter_app_build.md)
- [MLOps Pipeline](docs/guides/mlops_pipeline_setup.md)

## Benchmark Results

| Dataset | Top-1 Accuracy | TFLite Size | KL Divergence |
|---------|---------------|-------------|---------------|
| Tomato | 87.2% | ~0.96 MB | 0.000011 |
| Burmese Grape Leaf | 87.3% | ~0.96 MB | 0.000002 |

## License

This project is part of a capstone research project.
