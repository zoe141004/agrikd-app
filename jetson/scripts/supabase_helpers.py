"""Shared Supabase upload helpers for engine validation and benchmark reporting.

Extracted from engine_builder.py to break the cyclic import between
engine_builder and validate_engine.
"""

import hashlib
import logging
import os
import subprocess

import requests

log = logging.getLogger(__name__)


def get_hardware_tag():
    """Detect device hardware tag for engine cache matching.

    Format: {hw_model}_trt{trt_version}
    Example: jetson-orin-nx-8gb_trt10.3.0.30

    Mirrors sync_engine._get_hardware_tag() and setup_jetson.sh so that engines
    built/downloaded by any code path use the same Storage path and DB key.
    """
    hw_model = "unknown"
    trt_ver = "unknown"
    try:
        with open("/proc/device-tree/model", "r") as f:
            hw_model = f.read().strip().rstrip("\x00")
        hw_model = (hw_model.lower()
                    .replace("nvidia ", "")
                    .replace(" developer kit", "")
                    .replace(" ", "-"))
    except FileNotFoundError:
        pass
    try:
        result = subprocess.run(
            ["dpkg", "-l", "tensorrt"],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.splitlines():
            if line.startswith("ii"):
                trt_ver = line.split()[2].split("-")[0]
                break
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    if hw_model == "unknown" and trt_ver == "unknown":
        log.warning("Could not detect hardware tag, using 'unknown'")
        return "unknown"
    return f"{hw_model}_trt{trt_ver}"


def sha256_file(filepath):
    """Compute SHA-256 hash of a file."""
    if not os.path.isfile(filepath):
        raise FileNotFoundError(f"Cannot hash: {filepath} not found")
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def upload_engine_benchmark(base_url, key, leaf_type, version, hardware_tag, benchmark):
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


def upload_model_benchmark(base_url, key, leaf_type, version, benchmark):
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
        params={"on_conflict": "leaf_type,version,format"},
        json=payload,
        timeout=30,
        verify=True,
    )
    resp.raise_for_status()
    log.info("Benchmark uploaded to model_benchmarks (format=tensorrt_fp16)")
