# MLOps Pipeline Setup Guide

## Prerequisites

- Python 3.10+ (do NOT use the system Python which has old torch 1.12.1)
- Git, DVC
- CUDA 12.1+ (optional, for GPU training — CPU works for conversion/evaluation)
- Trained student checkpoints at `model_checkpoints_student/<leaf_type>_student.pth`
- Dataset at `data/<leaf_type>/` (required for evaluation step)

## 1. Create Virtual Environment

```bash
cd D:/Capstone/app
python -m venv venv_mlops
# Windows:
venv_mlops\Scripts\activate
# Linux/Mac:
source venv_mlops/bin/activate
```

## 2. Install Dependencies

```bash
# Install PyTorch first (CPU):
pip install torch==2.4.1 torchvision==0.19.1 --index-url https://download.pytorch.org/whl/cpu

# Or with CUDA 12.1:
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121

# Install pipeline dependencies:
cd mlops_pipeline
pip install -r requirements.txt
```

The `requirements.txt` includes two sub-files:
- `requirements-convert.txt` — conversion only (onnx, onnxruntime, tensorflow-cpu, onnx2tf, ai-edge-litert)
- `requirements-evaluate.txt` — full evaluation (adds pandas, matplotlib, seaborn, scikit-learn, thop)

## 3. DVC Setup

```bash
cd D:/Capstone/app

# Initialize DVC (skip if .dvc/ already exists)
dvc init

# Configure GCS remote
dvc remote add -d gcs gs://agrikd-dvc-data/data

# Pull datasets
dvc pull
```

For CI/CD, the `GOOGLE_APPLICATION_CREDENTIALS_DATA` secret (service account JSON) is used for authentication.

## 4. Config Files

Each leaf type has a config at `mlops_pipeline/configs/<leaf_type>.json`:

```json
{
    "leaf_type": "tomato",
    "display_name": "Ca chua (Tomato)",
    "num_classes": 10,
    "input_size": [224, 224],
    "input_channels": 3,
    "checkpoint_filename": "tomato_student.pth",
    "data_dir": "data/tomato",
    "classes": {
        "0": { "name": "Tomato___Bacterial_spot", "folder_name": "...", "display_name": "..." },
        ...
    },
    "normalization": {
        "mean": [0.485, 0.456, 0.406],
        "std": [0.229, 0.224, 0.225]
    }
}
```

**Critical:** Class indices follow ImageFolder alphabetical sort of `folder_name`. Always verify folder names in `data/<leaf_type>/` match the config JSON.

## 5. Run the Full Pipeline

```bash
cd D:/Capstone/app/mlops_pipeline/scripts

# Run for tomato:
python run_pipeline.py --config ../configs/tomato.json

# Run for burmese grape leaf:
python run_pipeline.py --config ../configs/burmese_grape_leaf.json

# Skip evaluation (convert + validate only):
python run_pipeline.py --config ../configs/tomato.json --skip-eval

# Skip validation:
python run_pipeline.py --config ../configs/tomato.json --skip-validate
```

### Pipeline Steps (in order)

| Step | Script | Description |
|------|--------|-------------|
| 1 | `convert_pth_to_onnx.py` | PTH to ONNX conversion (required) |
| 2 | `convert_onnx_to_tflite.py` | ONNX to TFLite (float16 + float32) |
| 3 | `validate_models.py` | Cross-format validation (optional) |
| 4 | `evaluate_models.py` | Full benchmark on test dataset (optional) |

## 6. Run Individual Scripts

```bash
# Convert PTH to ONNX:
python convert_pth_to_onnx.py --config ../configs/tomato.json

# Convert ONNX to TFLite:
python convert_onnx_to_tflite.py --config ../configs/tomato.json

# Validate cross-format consistency:
python validate_models.py --config ../configs/tomato.json

# Evaluate on test set:
python evaluate_models.py --config ../configs/tomato.json
```

## 7. Adding a New Dataset

1. Create config file: `mlops_pipeline/configs/<new_leaf_type>.json`
2. Place dataset in `data/<new_leaf_type>/` with ImageFolder structure:
   ```
   data/<new_leaf_type>/
   ├── train/
   │   ├── ClassA/
   │   ├── ClassB/
   │   └── ...
   ├── val/
   └── test/
   ```
3. Train the student model and save checkpoint to `model_checkpoints_student/<new_leaf_type>_student.pth`
4. Run the pipeline: `python run_pipeline.py --config ../configs/<new_leaf_type>.json`
5. Track with DVC: `dvc add data/<new_leaf_type>` then `dvc push`

## 8. Output Files

After a successful run, outputs are at:

```
models/<leaf_type>/
├── <leaf_type>_student.onnx           # ONNX model
├── <leaf_type>_student.tflite         # TFLite float16 (default)
├── <leaf_type>_student_float32.tflite # TFLite float32
├── benchmark_report_<leaf_type>.txt   # Text report
├── benchmark_report_<leaf_type>.csv   # CSV metrics
└── benchmark_chart_<leaf_type>.png    # Comparison chart
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `validate_models.py` shows FAIL | Expected on random noise inputs — uses fresh model instances with different batch norm stats. Not a real failure. |
| `convert_pth_to_tflite.py` fails | ai-edge-torch only works on Linux. Use the 2-step path (PTH→ONNX→TFLite) instead. |
| Windows encoding errors with Vietnamese | The pipeline has a UTF-8 reconfigure fix. Ensure `venv_mlops` is active. |
| PTH→ONNX fails | Hard stop. Check checkpoint path and config. |
| TFLite conversion fails | Non-fatal warning. ONNX model still usable. |
| Evaluation step skipped | Dataset directory `data/<leaf_type>/` is missing. Run `dvc pull` first. |
