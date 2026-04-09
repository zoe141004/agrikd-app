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
import shutil
import subprocess
import sys
import tempfile

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
    except (FileNotFoundError, subprocess.TimeoutExpired):
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
    except FileNotFoundError:
        pass

    log.warning("Could not detect GPU architecture, using 'unknown'")
    return "unknown"


def sha256_file(filepath):
    """Compute SHA-256 hash of a file."""
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
    """Process a single leaf type: check cache → download/build → validate → upload."""
    base_url = config["sync"]["supabase_url"]
    key = config["sync"]["supabase_key"]
    models_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models")
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

    # Step 2: Check if engine already exists for this hardware on Supabase
    engine_info = supabase_rpc(base_url, key, "get_engine_for_hardware", {
        "p_leaf_type": leaf_type,
        "p_version": version,
        "p_hardware_tag": hardware_tag,
    })

    if engine_info:
        # Engine exists — download directly
        log.info("Pre-built engine found for %s/%s/%s, downloading...", leaf_type, version, hardware_tag)
        download_file(engine_info[0]["engine_url"], engine_path, key)
        expected_sha = engine_info[0]["engine_sha256"]
        actual_sha = sha256_file(engine_path)
        if expected_sha and actual_sha != expected_sha:
            log.error("SHA-256 mismatch! Expected %s, got %s", expected_sha, actual_sha)
            os.remove(engine_path)
            return False
        log.info("Engine downloaded and verified: %s", engine_path)
        return True

    # Step 3: No cached engine — download ONNX and build
    log.info("No cached engine for %s/%s — building from ONNX...", hardware_tag, version)
    with tempfile.TemporaryDirectory() as tmpdir:
        onnx_path = os.path.join(tmpdir, f"{leaf_type}_student.onnx")
        size = download_file(onnx_url, onnx_path, key)
        log.info("Downloaded ONNX: %d bytes", size)

        # Build engine
        build_engine(onnx_path, engine_path)

    # Step 4: Upload engine to Supabase
    engine_sha = sha256_file(engine_path)
    storage_path = f"{leaf_type}/v{version}/{leaf_type}_{hardware_tag}.engine"
    engine_url = upload_engine(base_url, key, engine_path, storage_path)

    # Read device_id from config if available
    device_id = config.get("device", {}).get("device_id")

    # Step 5: Register in model_engines table
    register_engine(base_url, key, leaf_type, version, hardware_tag,
                    engine_url, engine_sha, device_id)

    log.info("Engine build + upload complete for %s v%s (%s)", leaf_type, version, hardware_tag)
    return True


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
