#!/usr/bin/env python3
"""
AgriKD Engine Builder — Build, validate, and upload TensorRT engines.

This script handles the full engine lifecycle for Jetson devices:
1. Check if a pre-built .engine exists on Supabase for this hardware
2. If yes: download it directly (skip build)
3. If no: download ONNX → build with trtexec → upload .engine to Supabase
4. Optionally: pull DVC dataset → validate accuracy → upload benchmark → cleanup

Usage:
    python engine_builder.py --config /opt/agrikd/config/config.json
    python engine_builder.py --config config.json --leaf-type tomato --validate
"""

import argparse
import hashlib
import json
import logging
import os
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

import requests

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("engine_builder")


def get_hardware_tag():
    """Detect NVIDIA GPU SM architecture for engine compatibility tagging."""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            cap = result.stdout.strip().split("\n")[0].replace(".", "")
            return f"sm{cap}"
    except (FileNotFoundError, subprocess.TimeoutExpired):  # nvidia-smi not found
        pass

    # Fallback: check /proc/device-tree for Jetson model
    try:
        with open("/proc/device-tree/model", "r") as f:
            model = f.read().strip().lower()
        if "orin" in model:
            return "sm87"
        elif "xavier" in model:
            return "sm72"
        elif "nano" in model or "tx1" in model:
            return "sm53"
        elif "tx2" in model:
            return "sm62"
    except FileNotFoundError:  # /proc/device-tree/model not found
        pass

    log.warning("Could not detect GPU architecture, using 'unknown'")
    return "unknown"


def sha256_file(filepath):
    """Compute SHA-256 hash of a file."""
    if not os.path.isfile(filepath):
        raise FileNotFoundError(f"Cannot hash: {filepath} not found")
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def supabase_rpc(base_url, key, function_name, params):
    """Call a Supabase RPC function."""
    url = f"{base_url}/rest/v1/rpc/{function_name}"
    resp = requests.post(
        url,
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        json=params,
        timeout=30,
        verify=True,
    )
    resp.raise_for_status()
    return resp.json()


def _validate_storage_url(url, base_url):
    """Validate that a download URL is HTTPS and on the configured Supabase host.

    Prevents SSRF by rejecting URLs that point outside our Supabase storage,
    contain embedded credentials, or use non-standard ports.
    """
    try:
        parsed = urlparse(url)
        allowed_host = urlparse(base_url).hostname
    except Exception as exc:
        raise ValueError(f"Malformed URL: {url[:80]}") from exc
    if parsed.scheme != "https":
        raise ValueError(f"Only HTTPS download URLs are allowed: {url[:80]}")
    if parsed.hostname != allowed_host:
        raise ValueError(
            f"Download URL host '{parsed.hostname}' does not match "
            f"configured Supabase host '{allowed_host}'"
        )
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("Download URLs must not contain embedded credentials")
    if parsed.port is not None and parsed.port != 443:
        raise ValueError(
            f"Download URL uses non-standard port {parsed.port}; only 443 is allowed"
        )


def download_file(url, dest_path, key=None):
    """Download a file from URL with optional auth header."""
    headers = {}
    if key:
        headers["apikey"] = key
        headers["Authorization"] = f"Bearer {key}"

    resp = requests.get(url, headers=headers, stream=True, timeout=120, verify=True)
    resp.raise_for_status()

    with open(dest_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=8192):
            f.write(chunk)

    return os.path.getsize(dest_path)


def upload_engine(base_url, key, local_path, storage_path):
    """Upload .engine file to Supabase Storage bucket 'models'."""
    upload_url = f"{base_url}/storage/v1/object/models/{storage_path}"

    with open(local_path, "rb") as f:
        file_data = f.read()

    resp = requests.post(
        upload_url,
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/octet-stream",
            "x-upsert": "true",
        },
        data=file_data,
        timeout=300,
        verify=True,
    )
    resp.raise_for_status()

    public_url = f"{base_url}/storage/v1/object/public/models/{storage_path}"
    log.info("Uploaded engine to: %s", public_url)
    return public_url


def register_engine(base_url, key, leaf_type, version, hardware_tag,
                    engine_url, engine_sha256, device_id=None, benchmark=None):
    """Register engine in model_engines table via REST API."""
    url = f"{base_url}/rest/v1/model_engines"
    payload = {
        "leaf_type": leaf_type,
        "version": version,
        "hardware_tag": hardware_tag,
        "engine_url": engine_url,
        "engine_sha256": engine_sha256,
    }
    if device_id:
        payload["created_by_device"] = device_id
    if benchmark:
        payload["benchmark_json"] = benchmark

    resp = requests.post(
        url,
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal,resolution=merge-duplicates",
        },
        json=payload,
        timeout=30,
        verify=True,
    )
    resp.raise_for_status()
    log.info("Registered engine in model_engines table")


def build_engine(onnx_path, engine_path):
    """Build TensorRT engine from ONNX using trtexec."""
    cmd = [
        "trtexec",
        f"--onnx={onnx_path}",
        f"--saveEngine={engine_path}",
        "--fp16",
        "--workspace=1024",
    ]
    log.info("Building engine: %s", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if result.returncode != 0:
        log.error("trtexec failed:\n%s", result.stderr[-2000:] if result.stderr else "no output")
        raise RuntimeError(f"trtexec exited with code {result.returncode}")
    log.info("Engine built successfully: %s", engine_path)


def process_leaf_type(config, leaf_type, hardware_tag, validate=False):
    """Process a single leaf type: check cache → download/build → validate → upload.

    Validation flow (when --validate is set):
      - If engine pulled from cache AND benchmark_json already exists → skip eval
      - If engine pulled from cache but NO benchmark_json → run eval, upload benchmark
      - If engine built from ONNX (new) → run eval, upload benchmark
    After eval, dataset is always deleted to conserve storage.
    """
    base_url = config["sync"]["supabase_url"]
    key = config["sync"]["supabase_key"]
    models_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models")
    os.makedirs(models_dir, exist_ok=True)
    engine_path = os.path.join(models_dir, f"{leaf_type}_student.engine")

    log.info("=== Processing: %s (hardware: %s) ===", leaf_type, hardware_tag)

    # Step 1: Get latest ONNX info from model_registry
    onnx_info = supabase_rpc(base_url, key, "get_latest_onnx_url", {"p_leaf_type": leaf_type})
    if not onnx_info:
        log.warning("No active ONNX model found for %s — skipping", leaf_type)
        return False

    version = onnx_info[0]["version"]
    onnx_url = onnx_info[0]["onnx_url"]
    log.info("Latest version: %s, ONNX URL: %s", version, onnx_url[:80])

    needs_benchmark = validate  # assume we need benchmark if --validate

    # Step 2: Check if engine already exists for this hardware on Supabase
    engine_info = supabase_rpc(base_url, key, "get_engine_for_hardware", {
        "p_leaf_type": leaf_type,
        "p_version": version,
        "p_hardware_tag": hardware_tag,
    })

    if engine_info:
        # Engine exists — download directly
        log.info("Pre-built engine found for %s/%s/%s, downloading...", leaf_type, version, hardware_tag)
        _validate_storage_url(engine_info[0]["engine_url"], base_url)
        download_file(engine_info[0]["engine_url"], engine_path, key)
        expected_sha = engine_info[0]["engine_sha256"]
        actual_sha = sha256_file(engine_path)
        if expected_sha and actual_sha != expected_sha:
            log.error("SHA-256 mismatch! Expected %s, got %s", expected_sha, actual_sha)
            os.remove(engine_path)
            return False
        log.info("Engine downloaded and verified: %s", engine_path)

        # Check if benchmark already exists for this engine
        if validate and engine_info[0].get("benchmark_json"):
            log.info("Benchmark already exists for %s/%s/%s — skipping validation",
                     leaf_type, version, hardware_tag)
            needs_benchmark = False
    else:
        # Step 3: No cached engine — download ONNX and build
        log.info("No cached engine for %s/%s — building from ONNX...", hardware_tag, version)
        with tempfile.TemporaryDirectory() as tmpdir:
            onnx_path = os.path.join(tmpdir, f"{leaf_type}_student.onnx")
            _validate_storage_url(onnx_url, base_url)
            size = download_file(onnx_url, onnx_path, key)
            log.info("Downloaded ONNX: %d bytes", size)

            # Build engine
            build_engine(onnx_path, engine_path)

        # Step 4: Upload engine to Supabase
        engine_sha = sha256_file(engine_path)
        storage_path = f"{leaf_type}/v{version}/{leaf_type}_{hardware_tag}.engine"
        engine_url_remote = upload_engine(base_url, key, engine_path, storage_path)

        # Read device_id from config if available
        device_id = config.get("device", {}).get("device_id")

        # Step 5: Register in model_engines table
        register_engine(base_url, key, leaf_type, version, hardware_tag,
                        engine_url_remote, engine_sha, device_id)

        log.info("Engine build + upload complete for %s v%s (%s)", leaf_type, version, hardware_tag)

    # Step 6: On-device validation (if --validate and benchmark not yet present)
    if needs_benchmark:
        try:
            _run_validation(config, leaf_type, version, hardware_tag, engine_path)
        except Exception as e:
            log.error("Validation failed for %s (non-fatal): %s", leaf_type, e)

    return True


def _run_validation(config, leaf_type, version, hardware_tag, engine_path):
    """Pull dataset via DVC, evaluate TensorRT engine, upload benchmark, cleanup."""
    from validate_engine import (
        _find_repo_root,
        setup_gcs_credentials,
        dvc_pull_dataset,
        load_test_images,
        run_tensorrt_inference,
        compute_metrics,
        cleanup_dataset,
    )

    base_url = config["sync"]["supabase_url"]
    key = config["sync"]["supabase_key"]
    num_classes = config.get("models", {}).get(leaf_type, {}).get("num_classes")
    input_size = config.get("inference", {}).get("input_size", 224)
    repo_root = _find_repo_root()
    if not repo_root:
        raise RuntimeError("Could not find repo root (no dvc/ directory). Pass --repo-root.")

    if not num_classes:
        raise ValueError(f"num_classes not configured for {leaf_type}")

    data_dir = None
    try:
        # 6a. Setup GCS credentials and pull dataset
        setup_gcs_credentials(config)
        data_dir = dvc_pull_dataset(leaf_type, repo_root)

        # 6b. Load test images (same stratified split as CI pipeline)
        images, labels, class_names = load_test_images(data_dir, input_size)
        log.info("Loaded %d test images across %d classes", len(images), len(class_names))

        # 6c. Run TensorRT inference
        predictions, probs, latencies = run_tensorrt_inference(
            engine_path, images, num_classes
        )

        # 6d. Compute metrics
        benchmark = compute_metrics(
            predictions, labels, probs, latencies, engine_path, class_names
        )
        benchmark["hardware_tag"] = hardware_tag

        # 6e. Upload to model_engines.benchmark_json (device-specific)
        _upload_engine_benchmark(base_url, key, leaf_type, version, hardware_tag, benchmark)

        # 6f. Upload to model_benchmarks table (dashboard display)
        _upload_model_benchmark(base_url, key, leaf_type, version, benchmark)

        log.info("Validation complete for %s v%s (%s)", leaf_type, version, hardware_tag)

    finally:
        # 6g. Always cleanup dataset
        if data_dir:
            cleanup_dataset(data_dir)
        os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS", None)


def _upload_engine_benchmark(base_url, key, leaf_type, version, hardware_tag, benchmark):
    """Update model_engines record with benchmark_json."""
    url = (
        f"{base_url}/rest/v1/model_engines"
        f"?leaf_type=eq.{leaf_type}"
        f"&version=eq.{version}"
        f"&hardware_tag=eq.{hardware_tag}"
    )
    resp = requests.patch(
        url,
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        },
        json={"benchmark_json": benchmark},
        timeout=30,
        verify=True,
    )
    resp.raise_for_status()
    log.info("Benchmark uploaded to model_engines.benchmark_json")


def _upload_model_benchmark(base_url, key, leaf_type, version, benchmark):
    """Upsert TensorRT benchmark into model_benchmarks table for dashboard display."""
    url = f"{base_url}/rest/v1/model_benchmarks"
    payload = {
        "leaf_type": leaf_type,
        "version": version,
        "format": "tensorrt_fp16",
        "accuracy": benchmark.get("accuracy"),
        "precision_macro": benchmark.get("precision_macro"),
        "recall_macro": benchmark.get("recall_macro"),
        "f1_macro": benchmark.get("f1_macro"),
        "latency_mean_ms": benchmark.get("latency_mean_ms"),
        "latency_p99_ms": benchmark.get("latency_p99_ms"),
        "fps": benchmark.get("fps"),
        "size_mb": benchmark.get("size_mb"),
        "is_candidate": False,
    }
    resp = requests.post(
        url,
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal,resolution=merge-duplicates",
        },
        json=payload,
        timeout=30,
        verify=True,
    )
    resp.raise_for_status()
    log.info("Benchmark uploaded to model_benchmarks (format=tensorrt_fp16)")


def main():
    parser = argparse.ArgumentParser(description="AgriKD Engine Builder")
    parser.add_argument("--config", required=True, help="Path to config.json")
    parser.add_argument("--leaf-type", help="Process specific leaf type (default: all)")
    parser.add_argument("--validate", action="store_true", help="Run on-device validation after build")
    args = parser.parse_args()

    if not os.path.exists(args.config):
        log.error("Config file not found: %s", args.config)
        sys.exit(1)

    with open(args.config) as f:
        config = json.load(f)

    if not config.get("sync", {}).get("supabase_url"):
        log.error("Missing sync.supabase_url in config")
        sys.exit(1)

    hardware_tag = get_hardware_tag()
    log.info("Detected hardware: %s", hardware_tag)

    leaf_types = [args.leaf_type] if args.leaf_type else list(config.get("models", {}).keys())
    if not leaf_types:
        log.error("No leaf types found in config.models")
        sys.exit(1)

    success_count = 0
    for lt in leaf_types:
        try:
            if process_leaf_type(config, lt, hardware_tag, args.validate):
                success_count += 1
        except Exception as e:
            log.error("Failed to process %s: %s", lt, e)

    log.info("Done: %d/%d leaf types processed successfully", success_count, len(leaf_types))
    sys.exit(0 if success_count == len(leaf_types) else 1)


if __name__ == "__main__":
    main()
