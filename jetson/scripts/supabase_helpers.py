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
        json=payload,
        timeout=30,
        verify=True,
    )
    resp.raise_for_status()
    log.info("Benchmark uploaded to model_benchmarks (format=tensorrt_fp16)")
