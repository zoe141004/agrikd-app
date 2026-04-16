#!/usr/bin/env python3
"""
AgriKD Engine Validator — On-device TensorRT engine evaluation.

Provides reusable functions for:
  - Pulling test datasets via DVC (GCS-backed)
  - Running TensorRT inference with GPU timing
  - Computing classification + performance metrics
  - Cleaning up datasets after evaluation

Called by engine_builder.py when --validate is passed.
Can also run standalone for manual validation.

Requires:
    - dvc, dvc-gs (pip)
    - GCS service account key at config.gcs.credentials_path
    - TensorRT + PyCUDA (JetPack)
    - scikit-learn, opencv-python-headless

Usage (standalone):
    python validate_engine.py --config config.json --leaf-type tomato
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import time

import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("validate_engine")

# Matches the CI pipeline split exactly (evaluate_models.py)
SEED = 42
TRAIN_RATIO = 0.70
VAL_RATIO = 0.10
TEST_RATIO = 0.20

# ImageNet normalization (same as inference.py and evaluate_models.py)
IMAGENET_MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
IMAGENET_STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)

# Mapping from leaf_type key to DVC file name
LEAF_TYPE_TO_DVC = {
    "tomato": "data_tomato.dvc",
    "burmese_grape_leaf": "data_burmese_grape_leaf.dvc",
    "potato_dataset": "data_potato_dataset.dvc",
    "potato": "data_potato_dataset.dvc",
}

# Mapping from leaf_type key to data directory name
LEAF_TYPE_TO_DIR = {
    "tomato": "tomato",
    "burmese_grape_leaf": "burmese_grape_leaf",
    "potato_dataset": "potato_dataset",
    "potato": "potato_dataset",
}


def parse_fold_from_version(version_str):
    """Extract fold number from a version string like 'v1.2.3-fold5'.

    Returns fold number (int, 1-indexed) or None if not present.
    """
    import re
    if not version_str:
        return None
    m = re.search(r'-fold(\d+)', version_str)
    if m:
        fold = int(m.group(1))
        if fold < 1 or fold > 5:
            log.warning("Fold %d out of expected range [1,5], using anyway", fold)
        return fold
    return None


def _find_repo_root(start_path=None):
    """Find the project root by looking for the dvc/ directory.

    Works in both dev context (jetson/scripts/) and Jetson deploy (/opt/agrikd/scripts/).
    """
    current = start_path or os.path.dirname(os.path.abspath(__file__))
    for _ in range(5):
        if os.path.isdir(os.path.join(current, "dvc")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    return None


def setup_gcs_credentials(config, repo_root=None):
    """Set GOOGLE_APPLICATION_CREDENTIALS from config.

    Args:
        config: Config dict containing gcs.credentials_path
        repo_root: Optional repo root for resolving relative paths.
                   If not provided, uses parent of script directory.
    """
    gcs_config = config.get("gcs", {})
    creds_path = gcs_config.get("credentials_path")
    if not creds_path:
        raise RuntimeError(
            "GCS credentials path not configured. "
            "Set config.gcs.credentials_path to the service account JSON file."
        )
    if not os.path.isabs(creds_path):
        # Resolve relative to repo_root or fallback to script parent
        if repo_root:
            creds_path = os.path.join(repo_root, creds_path)
        else:
            base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            creds_path = os.path.join(base, creds_path)
    if not os.path.isfile(creds_path):
        raise FileNotFoundError(f"GCS credentials not found: {creds_path}")
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = creds_path
    log.info("GCS credentials set from: %s", creds_path)


def dvc_pull_dataset(leaf_type, repo_root):
    """Pull test dataset via DVC. Returns path to dataset directory.

    Cleans up stale DVC lock files before pulling to avoid lock conflicts.
    """
    dvc_file = LEAF_TYPE_TO_DVC.get(leaf_type)
    if not dvc_file:
        raise ValueError(f"Unknown leaf_type for DVC: {leaf_type}")

    dvc_path = os.path.join(repo_root, "dvc", dvc_file)
    if not os.path.isfile(dvc_path):
        raise FileNotFoundError(f"DVC file not found: {dvc_path}")

    data_dir_name = LEAF_TYPE_TO_DIR.get(leaf_type, leaf_type)
    data_dir = os.path.join(repo_root, "data", data_dir_name)

    # Clean up stale DVC lock files (from aborted processes)
    dvc_lock_file = os.path.join(repo_root, ".dvc", "tmp", "lock")
    if os.path.isfile(dvc_lock_file):
        try:
            os.remove(dvc_lock_file)
            log.info("Removed stale DVC lock file: %s", dvc_lock_file)
        except OSError:
            pass  # Race condition or permission issue - DVC will handle

    log.info("Pulling dataset via DVC: %s", dvc_file)
    result = subprocess.run(
        ["dvc", "pull", dvc_path],
        capture_output=True, text=True, timeout=600,
        cwd=repo_root,
    )
    if result.returncode != 0:
        log.error("DVC pull failed:\n%s", result.stderr[-2000:])
        raise RuntimeError(f"DVC pull failed with code {result.returncode}")

    if not os.path.isdir(data_dir):
        raise FileNotFoundError(f"Dataset directory not found after pull: {data_dir}")

    n_files = sum(len(files) for _, _, files in os.walk(data_dir))
    log.info("Dataset pulled: %s (%d files)", data_dir, n_files)
    return data_dir


def cleanup_dataset(data_dir, repo_root=None):
    """Remove downloaded dataset and DVC cache to conserve storage.

    On Jetson edge devices, storage is limited. After validation:
    1. Remove the extracted dataset directory
    2. Clear DVC cache (~/.dvc/cache or .dvc/cache) to free space

    Args:
        data_dir: Path to downloaded dataset directory
        repo_root: Optional repo root for locating local DVC cache.
                   If not provided, uses _find_repo_root().
    """
    if os.path.isdir(data_dir):
        shutil.rmtree(data_dir, ignore_errors=True)
        log.info("Cleaned up dataset: %s", data_dir)

    # Clear DVC cache to free storage
    # DVC stores downloaded files in cache before linking to workspace
    effective_repo_root = repo_root or _find_repo_root() or "."
    dvc_cache_paths = [
        os.path.expanduser("~/.dvc/cache"),  # Global cache
        os.path.join(effective_repo_root, ".dvc", "cache"),  # Local cache
    ]
    for cache_path in dvc_cache_paths:
        if os.path.isdir(cache_path):
            cache_size = sum(
                os.path.getsize(os.path.join(dp, f))
                for dp, _, fns in os.walk(cache_path)
                for f in fns
            )
            shutil.rmtree(cache_path, ignore_errors=True)
            log.info("Cleared DVC cache: %s (%.1f MB freed)",
                     cache_path, cache_size / 1024 / 1024)


def load_test_images(data_dir, input_size=224, cv_fold=None, cv_n_splits=5):
    """Load test split images using the same stratified split as CI pipeline.

    Two modes:
    - cv_fold=None: Standard stratified split (seed=42, 70/10/20).
    - cv_fold=N: Use StratifiedKFold(n_splits=cv_n_splits) and take fold N
      as test set (1-indexed), matching cross-validation research setup.

    Returns (images, labels, class_names) where images is a list of
    preprocessed numpy arrays in NCHW format.
    """
    from sklearn.model_selection import train_test_split

    # Discover classes from subdirectory names (ImageFolder convention)
    class_names = sorted(
        d for d in os.listdir(data_dir)
        if os.path.isdir(os.path.join(data_dir, d))
    )
    if not class_names:
        raise RuntimeError(f"No class subdirectories found in {data_dir}")

    # Collect all image paths and labels
    all_paths = []
    all_labels = []
    for cls_idx, cls_name in enumerate(class_names):
        cls_dir = os.path.join(data_dir, cls_name)
        for fname in sorted(os.listdir(cls_dir)):
            if fname.lower().endswith((".jpg", ".jpeg", ".png", ".bmp", ".webp")):
                all_paths.append(os.path.join(cls_dir, fname))
                all_labels.append(cls_idx)

    all_labels = np.array(all_labels)
    indices = np.arange(len(all_labels))

    if cv_fold is not None:
        # StratifiedKFold mode: fold N as test set
        from sklearn.model_selection import StratifiedKFold
        skf = StratifiedKFold(n_splits=cv_n_splits, shuffle=True, random_state=SEED)
        fold_iter = list(skf.split(indices, all_labels))
        fold_0idx = cv_fold - 1
        if fold_0idx < 0 or fold_0idx >= len(fold_iter):
            raise ValueError(f"cv_fold={cv_fold} out of range [1, {cv_n_splits}]")
        _, test_idx = fold_iter[fold_0idx]
        log.info("Using StratifiedKFold: fold %d/%d as test set", cv_fold, cv_n_splits)
    else:
        # Standard 70/10/20 stratified split
        _, temp_idx = train_test_split(
            indices,
            test_size=(VAL_RATIO + TEST_RATIO),
            stratify=all_labels,
            random_state=SEED,
        )
        temp_labels = all_labels[temp_idx]
        val_ratio_adj = VAL_RATIO / (VAL_RATIO + TEST_RATIO)
        _, test_idx = train_test_split(
            temp_idx,
            test_size=(1 - val_ratio_adj),
            stratify=temp_labels,
            random_state=SEED,
        )

    log.info("Test split: %d images out of %d total", len(test_idx), len(all_labels))

    # Preprocess test images using PIL (matching evaluate_models.py pipeline)
    # PIL and OpenCV use different interpolation, causing accuracy differences.
    from PIL import Image

    images = []
    valid_labels = []
    for idx in test_idx:
        try:
            pil_img = Image.open(all_paths[idx]).convert("RGB")
        except Exception:
            log.warning("Could not read image: %s", all_paths[idx])
            continue
        pil_img = pil_img.resize((input_size, input_size), Image.BILINEAR)
        img = np.array(pil_img, dtype=np.float32) / 255.0
        img = (img - IMAGENET_MEAN) / IMAGENET_STD
        img = np.transpose(img, (2, 0, 1))  # HWC → CHW
        images.append(img[np.newaxis, ...])  # Add batch dim: (1,3,H,W)
        valid_labels.append(all_labels[idx])

    if not images:
        raise RuntimeError(f"No test images loaded successfully from {data_dir}")

    return images, np.array(valid_labels), class_names


def run_tensorrt_inference(engine_path, images, num_classes, input_size=224):
    """Run TensorRT FP16 inference on a list of preprocessed images.

    Returns (predictions, latencies_ms) where predictions is an array of
    predicted class indices and latencies_ms is a list of per-image latencies.

    Uses pycuda.autoinit for safe CUDA context initialization.
    This script runs as a subprocess with its own isolated CUDA context.
    """
    import pycuda.autoinit  # noqa: F401 — auto-creates CUDA context safely
    import pycuda.driver as cuda

    try:
        import tensorrt as trt

        TRT_LOGGER = trt.Logger(trt.Logger.WARNING)
        runtime = trt.Runtime(TRT_LOGGER)

        with open(engine_path, "rb") as f:
            engine = runtime.deserialize_cuda_engine(f.read())
        context = engine.create_execution_context()

        # Allocate buffers (use configurable input_size, not hardcoded 224)
        input_shape = (1, 3, input_size, input_size)
        output_shape = (1, num_classes)
        h_input = cuda.pagelocked_empty(input_shape, dtype=np.float32)
        h_output = cuda.pagelocked_empty(output_shape, dtype=np.float32)
        d_input = cuda.mem_alloc(h_input.nbytes)
        d_output = cuda.mem_alloc(h_output.nbytes)
        stream = cuda.Stream()

        # Detect TensorRT version for correct execution API
        trt_major = int(trt.__version__.split(".")[0])

        if trt_major >= 10:
            input_name = engine.get_tensor_name(0)
            output_name = engine.get_tensor_name(1)
            context.set_tensor_address(input_name, int(d_input))
            context.set_tensor_address(output_name, int(d_output))

        predictions = []
        all_probs = []
        latencies_ms = []

        # Warmup (5 iterations)
        for _ in range(5):
            np.copyto(h_input, images[0])
            cuda.memcpy_htod_async(d_input, h_input, stream)
            if trt_major >= 10:
                context.execute_async_v3(stream_handle=stream.handle)
            else:
                context.execute_async_v2(bindings=[int(d_input), int(d_output)],
                                         stream_handle=stream.handle)
            cuda.memcpy_dtoh_async(h_output, d_output, stream)
            stream.synchronize()

        for img in images:
            np.copyto(h_input, img)

            start = time.perf_counter()
            cuda.memcpy_htod_async(d_input, h_input, stream)
            if trt_major >= 10:
                context.execute_async_v3(stream_handle=stream.handle)
            else:
                context.execute_async_v2(bindings=[int(d_input), int(d_output)],
                                         stream_handle=stream.handle)
            cuda.memcpy_dtoh_async(h_output, d_output, stream)
            stream.synchronize()
            elapsed_ms = (time.perf_counter() - start) * 1000

            logits = h_output.flatten()
            exp_logits = np.exp(logits - np.max(logits))
            probs = exp_logits / exp_logits.sum()

            predictions.append(int(np.argmax(probs)))
            all_probs.append(probs.copy())
            latencies_ms.append(elapsed_ms)

        # Cleanup GPU memory
        d_input.free()
        d_output.free()

        return np.array(predictions), np.array(all_probs), latencies_ms

    finally:
        # pycuda.autoinit handles context cleanup automatically
        pass


def compute_metrics(predictions, labels, probs, latencies_ms,
                    engine_path, class_names):
    """Compute classification and performance metrics."""
    from sklearn.metrics import accuracy_score, precision_score, recall_score, f1_score

    accuracy = accuracy_score(labels, predictions)
    precision = precision_score(labels, predictions, average="macro", zero_division=0)
    recall = recall_score(labels, predictions, average="macro", zero_division=0)
    f1 = f1_score(labels, predictions, average="macro", zero_division=0)

    latencies = np.array(latencies_ms)
    engine_size_mb = os.path.getsize(engine_path) / (1024 * 1024)

    benchmark = {
        "format": "tensorrt_fp16",
        "accuracy": round(accuracy * 100, 4),
        "precision_macro": round(float(precision), 4),
        "recall_macro": round(float(recall), 4),
        "f1_macro": round(float(f1), 4),
        "latency_mean_ms": round(float(latencies.mean()), 2),
        "latency_p99_ms": round(float(np.percentile(latencies, 99)), 2),
        "fps": round(1000.0 / float(latencies.mean()), 1) if latencies.mean() > 0 else 0,
        "size_mb": round(engine_size_mb, 2),
        "num_test_samples": len(labels),
        "num_classes": len(class_names),
        "class_names": class_names,
    }

    log.info(
        "Benchmark: acc=%.2f%% prec=%.4f rec=%.4f f1=%.4f "
        "latency=%.2fms fps=%.1f size=%.2fMB",
        benchmark["accuracy"], benchmark["precision_macro"],
        benchmark["recall_macro"], benchmark["f1_macro"],
        benchmark["latency_mean_ms"], benchmark["fps"],
        benchmark["size_mb"],
    )
    return benchmark


def main():
    """Standalone entry point — validates a single engine and uploads benchmark."""
    parser = argparse.ArgumentParser(description="AgriKD TensorRT Engine Validator")
    parser.add_argument("--config", required=True, help="Path to config.json")
    parser.add_argument("--leaf-type", required=True, help="Leaf type to validate")
    parser.add_argument("--version", help="Model version (auto-detected if omitted)")
    parser.add_argument("--engine-path", help="Path to engine file (auto-detected if omitted)")
    parser.add_argument("--hw-tag", help="Hardware tag (auto-detected if omitted)")
    parser.add_argument("--repo-root", help="Path to repo root containing dvc/ and data/")
    args = parser.parse_args()

    with open(args.config) as f:
        config = json.load(f)

    # Determine repo root (auto-detect by looking for dvc/ directory)
    repo_root = args.repo_root or _find_repo_root()
    if not repo_root:
        log.error("Could not find repo root (no dvc/ directory found). Use --repo-root.")
        sys.exit(1)

    leaf_type = args.leaf_type
    input_size = config.get("inference", {}).get("input_size", 224)
    model_cfg = config.get("models", {}).get(leaf_type, {})
    num_classes = model_cfg.get("num_classes")

    # Engine path: CLI arg > config > auto-detect
    engine_path = args.engine_path or model_cfg.get("engine_path")
    if engine_path and not os.path.isabs(engine_path):
        # Resolve relative path against repo_root
        engine_path = os.path.join(repo_root, engine_path)
    if not engine_path or not os.path.isfile(engine_path):
        # Auto-detect from repo_root/models/
        engine_path = os.path.join(repo_root, "models", f"{leaf_type}_student.engine")
    if not os.path.isfile(engine_path):
        log.error("Engine file not found: %s", engine_path)
        sys.exit(1)
    if not num_classes:
        log.error("num_classes not configured for %s", leaf_type)
        sys.exit(1)

    version = args.version or model_cfg.get("version")
    if not version:
        log.error("Model version not specified and not in config")
        sys.exit(1)

    # Parse fold from version string (e.g., "v1.2.3-fold5" → fold=5)
    cv_fold = parse_fold_from_version(version)

    # Hardware tag: CLI arg > auto-detect
    from supabase_helpers import get_hardware_tag
    hardware_tag = args.hw_tag or get_hardware_tag()

    data_dir = None
    try:
        setup_gcs_credentials(config, repo_root)
        data_dir = dvc_pull_dataset(leaf_type, repo_root)
        images, labels, class_names = load_test_images(data_dir, input_size, cv_fold=cv_fold)
        log.info("Loaded %d test images across %d classes", len(images), len(class_names))

        predictions, probs, latencies = run_tensorrt_inference(
            engine_path, images, num_classes
        )
        benchmark = compute_metrics(
            predictions, labels, probs, latencies, engine_path, class_names
        )
        benchmark["hardware_tag"] = hardware_tag

        # Upload to both tables via shared helpers
        # Support env vars for credentials (used when called from sync_engine subprocess)
        from supabase_helpers import upload_engine_benchmark, upload_model_benchmark
        base_url = os.environ.get("SUPABASE_URL") or config["sync"]["supabase_url"]
        key = os.environ.get("SUPABASE_KEY") or config["sync"]["supabase_key"]
        upload_engine_benchmark(base_url, key, leaf_type, version, hardware_tag, benchmark)
        upload_model_benchmark(base_url, key, leaf_type, version, benchmark)

        log.info("Validation done: %s v%s — acc=%.2f%% fps=%.1f",
                 leaf_type, version, benchmark.get("accuracy", 0), benchmark.get("fps", 0))

    except Exception as e:
        log.error("Validation failed for %s: %s", leaf_type, e)
        sys.exit(1)
    finally:
        if data_dir:
            cleanup_dataset(data_dir, repo_root)
        os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)


if __name__ == "__main__":
    main()
