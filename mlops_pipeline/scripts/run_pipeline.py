"""
AgriKD - Model Conversion Pipeline Orchestrator
================================================
Runs the full conversion pipeline for a single leaf model:
  1. PTH -> ONNX
  2. ONNX -> TFLite
  3. Cross-format validation
  4. Benchmark evaluation (optional, requires dataset)

Usage:
    python run_pipeline.py --config ../configs/tomato.json
    python run_pipeline.py --config ../configs/burmese_grape_leaf.json --skip-eval
"""

import argparse
import os
import sys
import subprocess
import time

# Fix Windows console encoding for Vietnamese characters in config display_names
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from model_definition import load_leaf_config

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))


def run_step(step_name, cmd):
    """Run a pipeline step via subprocess, print output, return success."""
    print(f"\n{'='*60}")
    print(f"  STEP: {step_name}")
    print(f"{'='*60}")
    print(f"  CMD:  {' '.join(cmd)}\n")

    start = time.perf_counter()
    result = subprocess.run(cmd, cwd=SCRIPTS_DIR)
    elapsed = time.perf_counter() - start

    if result.returncode != 0:
        print(f"\n[FAIL] {step_name} failed (exit code {result.returncode})")
        return False

    print(f"\n[OK] {step_name} completed in {elapsed:.1f}s")
    return True


def main():
    parser = argparse.ArgumentParser("AgriKD Pipeline Orchestrator")
    parser.add_argument("--config", required=True, help="Path to leaf config JSON")
    parser.add_argument("--skip-eval", action="store_true",
                        help="Skip evaluation step (convert + validate only)")
    parser.add_argument("--skip-validate", action="store_true",
                        help="Skip cross-format validation step")
    args = parser.parse_args()

    config_path = os.path.abspath(args.config)
    cfg = load_leaf_config(config_path)
    leaf = cfg["leaf_type"]

    print(f"\n{'#'*60}")
    print(f"  AgriKD Pipeline: {cfg.get('display_name', leaf)}")
    print(f"  Config: {config_path}")
    print(f"  Classes: {cfg['num_classes']}")
    print(f"  Output: {cfg['_paths']['output_dir']}")
    print(f"{'#'*60}")

    # Verify checkpoint exists
    ckpt = cfg["_paths"]["checkpoint"]
    if not os.path.exists(ckpt):
        print(f"\n[FAIL] Checkpoint not found: {ckpt}")
        sys.exit(1)

    python = sys.executable
    pipeline_ok = True

    # Step 1: PTH -> ONNX
    ok = run_step("PTH -> ONNX",
                  [python, os.path.join(SCRIPTS_DIR, "convert_pth_to_onnx.py"),
                   "--config", config_path])
    if not ok:
        sys.exit(1)

    # Step 2: ONNX -> TFLite
    ok = run_step("ONNX -> TFLite",
                  [python, os.path.join(SCRIPTS_DIR, "convert_onnx_to_tflite.py"),
                   "--config", config_path])
    if not ok:
        print("[CRITICAL] TFLite conversion failed — aborting pipeline")
        sys.exit(1)

    # Step 3: Cross-format validation
    if not args.skip_validate:
        ok = run_step("Cross-Format Validation",
                      [python, os.path.join(SCRIPTS_DIR, "validate_models.py"),
                       "--config", config_path])
        if not ok:
            print("[WARN] Validation had failures")
            pipeline_ok = False

    # Step 4: Benchmark evaluation
    if not args.skip_eval:
        data_dir = cfg["_paths"].get("data_dir")
        if data_dir and os.path.isdir(data_dir):
            ok = run_step("Benchmark Evaluation",
                          [python, os.path.join(SCRIPTS_DIR, "evaluate_models.py"),
                           "--config", config_path])
            if not ok:
                pipeline_ok = False
        else:
            print(f"\n[SKIP] Evaluation: dataset not found at {data_dir}")

    # Summary
    print(f"\n{'#'*60}")
    if pipeline_ok:
        print(f"  PIPELINE COMPLETE: {leaf}")
    else:
        print(f"  PIPELINE COMPLETE WITH WARNINGS: {leaf}")
    print(f"  Output: {cfg['_paths']['output_dir']}")
    print(f"{'#'*60}\n")

    sys.exit(0 if pipeline_ok else 1)


if __name__ == "__main__":
    main()
