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
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

import requests

from supabase_helpers import (
    get_hardware_tag,
    sha256_file,
    upload_engine_benchmark,
    upload_model_benchmark,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("engine_builder")


# get_hardware_tag and sha256_file are imported from supabase_helpers above


# Known JetPack / system locations for trtexec
_TRTEXEC_CANDIDATES = [
    "/usr/src/tensorrt/bin/trtexec",
    "/usr/local/cuda/bin/trtexec",
    "/usr/lib/tensorrt/bin/trtexec",
    "/opt/tensorrt/bin/trtexec",
    "/usr/local/bin/trtexec",
]


def _find_trtexec():
    """Locate trtexec binary (PATH → known JetPack locations → ~/trtexec)."""
    path = shutil.which("trtexec")
    if path:
        return path
    for candidate in _TRTEXEC_CANDIDATES:
        if os.path.isfile(candidate):
            return candidate
    home = os.path.expanduser("~/trtexec")
    if os.path.isfile(home):
        return home
    return None


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
    """Upload .engine file to Supabase Storage bucket 'models' (streamed)."""
    upload_url = f"{base_url}/storage/v1/object/models/{storage_path}"
    file_size = os.path.getsize(local_path)

    # Stream the file in chunks to avoid loading the full engine (~100-500 MB)
    # into RAM on memory-constrained Jetson devices.
    with open(local_path, "rb") as f:
        resp = requests.post(
            upload_url,
            headers={
                "apikey": key,
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/octet-stream",
                "Content-Length": str(file_size),
                "x-upsert": "true",
            },
            data=f,
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


def build_engine(onnx_path, engine_path, workspace_mb=1024):
    """Build TensorRT engine from ONNX using trtexec.

    Args:
        onnx_path:    Path to the source .onnx file.
        engine_path:  Destination path for the .engine file.
        workspace_mb: Max workspace size in MB for TRT builder (default 1024).
    """
    trtexec_bin = _find_trtexec()
    if not trtexec_bin:
        raise FileNotFoundError(
            "trtexec not found in PATH or known JetPack locations"
        )
    cmd = [
        trtexec_bin,
        f"--onnx={onnx_path}",
        f"--saveEngine={engine_path}",
        "--fp16",
        f"--memPoolSize=workspace:{workspace_mb}M",
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

    # Read locally configured version and engine_path from config.json
    model_cfg = config.get("models", {}).get(leaf_type, {})
    local_version = model_cfg.get("version", "")
    local_engine_rel = model_cfg.get("engine_path", "")
    local_engine_path = ""
    if local_engine_rel:
        # Resolve relative to install root (parent of scripts/)
        install_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        local_engine_path = os.path.join(install_root, local_engine_rel)

    log.info("=== Processing: %s (hardware: %s) ===", leaf_type, hardware_tag)

    # Step 1: Get latest ONNX info from model_registry
    onnx_info = supabase_rpc(base_url, key, "get_latest_onnx_url", {"p_leaf_type": leaf_type})
    if not onnx_info:
        log.warning("No active ONNX model found for %s — skipping", leaf_type)
        return False

    version = onnx_info[0]["version"]
    onnx_url = onnx_info[0]["onnx_url"]
    log.info("Latest version: %s, ONNX URL: %s", version, onnx_url[:80])

    # Use versioned engine path
    engine_path = os.path.join(models_dir, f"{leaf_type}_student_v{version}.engine")

    # Check if local engine already exists for this version (or a compatible one)
    if local_engine_path and os.path.isfile(local_engine_path) and local_version == version:
        log.info("Engine already exists locally: %s (v%s) — skipping build",
                 local_engine_path, local_version)
        engine_path = local_engine_path
    elif os.path.isfile(engine_path):
        log.info("Engine already exists locally: %s — skipping build", engine_path)
    else:
        needs_benchmark = validate

        # Step 2: Check if engine already exists for this hardware on Supabase
        engine_info = supabase_rpc(base_url, key, "get_engine_for_hardware", {
            "p_leaf_type": leaf_type,
            "p_version": version,
            "p_hardware_tag": hardware_tag,
        })

        if engine_info:
            # Engine exists on Supabase — download directly
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
            storage_path = f"engines/{leaf_type}/{version}/{hardware_tag}.engine"
            engine_url_remote = upload_engine(base_url, key, engine_path, storage_path)

            # Read device_id from config if available
            device_id = config.get("device", {}).get("device_id")

            # Step 5: Register in model_engines table
            register_engine(base_url, key, leaf_type, version, hardware_tag,
                            engine_url_remote, engine_sha, device_id)

            log.info("Engine build + upload complete for %s v%s (%s)", leaf_type, version, hardware_tag)

    # Step 6: On-device validation (if --validate)
    needs_benchmark = validate
    if needs_benchmark:
        # Check Supabase for existing benchmark before running expensive eval
        engine_info = supabase_rpc(base_url, key, "get_engine_for_hardware", {
            "p_leaf_type": leaf_type,
            "p_version": version,
            "p_hardware_tag": hardware_tag,
        })
        if engine_info and engine_info[0].get("benchmark_json"):
            log.info("Benchmark already exists for %s/%s/%s — skipping validation",
                     leaf_type, version, hardware_tag)
            needs_benchmark = False

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
            engine_path, images, num_classes, input_size=input_size
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


# Backward-compat aliases — delegate to supabase_helpers
_upload_engine_benchmark = upload_engine_benchmark
_upload_model_benchmark = upload_model_benchmark


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
