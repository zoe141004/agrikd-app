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

- [Project Architecture & Overview](docs/project_context.md)
- [Product Release Guide](docs/product_release.md)
- [Contributing / Developer Setup](CONTRIBUTING.md)
- [Admin Dashboard Manual](docs/admin_dashboard_manual.md)
- [Jetson Deployment & GUI Guide](docs/jetson_deployment_guide.md)

## Benchmark Results

| Dataset | Top-1 Accuracy | TFLite Size | KL Divergence |
|---------|---------------|-------------|---------------|
| Tomato | 87.2% | ~0.96 MB | 0.000011 |
| Burmese Grape Leaf | 87.3% | ~0.96 MB | 0.000002 |

## License

This project is part of a capstone research project.
