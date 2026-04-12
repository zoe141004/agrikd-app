"""
AgriKD Jetson Edge Inference Application
=========================================
Main entry point for running plant disease inference on NVIDIA Jetson devices.

Features:
- TensorRT FP16 inference via InferenceWorkerPool (thread-safe)
- USB/CSI camera capture with Wake-Capture-Sleep in periodic mode
- SQLite local database (WAL mode, thread-safe locking)
- HTTP sync to Supabase (background daemon thread)
- REST API health check endpoint (/health, /predict)
- Dynamic schedule via Device Shadow (desired_config polling)
- Graceful shutdown with sync drain

LOCAL-FIRST guarantee: This file NEVER imports requests, NEVER calls HTTP,
NEVER blocks on network. All network I/O is in sync_engine (daemon thread).
Device state is READ-ONLY here — sync_engine is the single writer.
"""

import json
import logging
import os
import signal
import socket
import sys
import threading
import time

from camera import CameraCapture
from database import JetsonDatabase
from health_server import start_health_server
from inference import InferenceWorkerPool
from sync_engine import SyncEngine


def _notify_watchdog():
    """Send sd_notify WATCHDOG=1 heartbeat to systemd (if running as service)."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        if addr.startswith("@"):
            addr = "\0" + addr[1:]
        sock.sendto(b"WATCHDOG=1", addr)
        sock.close()
    except OSError:  # systemd watchdog socket unavailable
        pass


def _read_device_state(path, retries=1, delay=0.05):
    """Read device_state.json with retry for atomic-replace window.

    Fix 1.8: os.replace() during atomic write creates a brief window where
    the file may not exist.  Retry once after a short delay.
    """
    for attempt in range(1 + retries):
        try:
            with open(path) as f:
                data = json.load(f)
                if data.get("device_token") and data.get("device_id"):
                    return data
                return None
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            if attempt < retries:
                time.sleep(delay)
    return None


def setup_logging(config):
    """Configure logging with rotation."""
    log_cfg = config.get("logging", {})
    log_file = log_cfg.get("file", "logs/agrikd.log")
    os.makedirs(os.path.dirname(log_file), exist_ok=True)

    from logging.handlers import RotatingFileHandler

    handler = RotatingFileHandler(
        log_file,
        maxBytes=log_cfg.get("max_bytes", 10 * 1024 * 1024),
        backupCount=log_cfg.get("backup_count", 3),
    )
    handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_cfg.get("level", "INFO")))
    root.addHandler(handler)
    root.addHandler(logging.StreamHandler(sys.stdout))


def load_config(path="config/config.json"):
    """Load configuration from JSON file with schema validation."""
    with open(path, "r") as f:
        config = json.load(f)

    # Required top-level sections and their mandatory keys
    schema = {
        "camera": ["source"],
        "models": [],  # non-empty dict checked separately
        "sync": ["supabase_url", "interval_seconds"],
        "server": ["host", "port"],
        "database": ["path"],
    }
    errors = []
    for section, keys in schema.items():
        if section not in config:
            errors.append(f"Missing required section: '{section}'")
            continue
        for key in keys:
            if key not in config[section]:
                errors.append(f"Missing '{section}.{key}'")

    # Validate each model entry has required fields
    models = config.get("models", {})
    if not models:
        errors.append("'models' must contain at least one entry")
    for leaf_type, mcfg in models.items():
        for key in ("engine_path", "num_classes", "class_labels"):
            if key not in mcfg:
                errors.append(f"Missing 'models.{leaf_type}.{key}'")

    if errors:
        raise ValueError(
            "Config validation failed:\n  - " + "\n  - ".join(errors)
        )

    return config


def check_ready(config):
    """Run preflight checks — fail fast with clear error if anything is missing."""
    errors = []

    # Check TensorRT and PyCUDA imports
    try:
        import tensorrt  # noqa: F401
    except ImportError:
        errors.append("TensorRT is not installed")

    try:
        import pycuda.driver as cuda
        cuda.init()
        if cuda.Device.count() == 0:
            errors.append("No CUDA devices found")
    except ImportError:
        errors.append("PyCUDA is not installed")
    except Exception as e:
        errors.append(f"CUDA init failed: {e}")

    # Check model engine files
    for leaf_type, model_cfg in config.get("models", {}).items():
        engine_path = model_cfg.get("engine_path", "")
        if not os.path.isfile(engine_path):
            errors.append(f"Engine file missing for {leaf_type}: {engine_path}")

    # Check camera source exists (for device paths)
    cam_source = config.get("camera", {}).get("source", "")
    if cam_source.startswith("/dev/") and not os.path.exists(cam_source):
        errors.append(f"Camera device not found: {cam_source}")

    # Check database directory is writable
    db_path = config.get("database", {}).get("path", "")
    if db_path:
        db_dir = os.path.dirname(db_path) or "."
        if not os.access(db_dir, os.W_OK):
            errors.append(f"Database directory not writable: {db_dir}")

    if errors:
        raise RuntimeError(
            "Preflight checks failed:\n  - " + "\n  - ".join(errors)
        )


def main():
    # Resolve working directory to install root so relative paths
    # in config (models/, config/, data/) resolve correctly.
    # Docker layout: /app/main.py + /app/config/ → use script dir
    # Host layout:   /opt/agrikd/app/main.py + /opt/agrikd/config/ → use parent
    script_dir = os.path.dirname(os.path.abspath(__file__))
    if os.path.isdir(os.path.join(script_dir, "config")):
        install_root = script_dir
    else:
        install_root = os.path.dirname(script_dir)
    os.chdir(install_root)

    config = load_config()
    setup_logging(config)
    logger = logging.getLogger("main")

    logger.info("=" * 50)
    logger.info("AgriKD Jetson Edge Inference - Starting")
    logger.info("=" * 50)

    # Preflight checks — fail fast before allocating resources
    check_ready(config)
    logger.info("Preflight checks passed")

    # Fix 1.8: Read device state with retry for atomic-replace safety
    device_state_path = os.path.join("data", "device_state.json")
    device_state = _read_device_state(device_state_path)
    device_id = None
    if device_state:
        device_id = device_state.get("device_id")
        logger.info(
            "Device provisioned: id=%s, hw_id=%s",
            device_id,
            device_state.get("hw_id", "")[:12],
        )
    else:
        logger.info("No device state — running as standalone (local-only)")

    # Initialize database (WAL mode, thread-safe locking)
    db = JetsonDatabase(config["database"]["path"])
    logger.info("Database initialized: %s", config["database"]["path"])

    # Fix 1.1: Load TensorRT engines via InferenceWorkerPool.
    # Engines are created on the worker thread which owns the CUDA context.
    pool = InferenceWorkerPool(
        config["models"],
        inference_config=config.get("inference", {}),
    )
    logger.info("InferenceWorkerPool ready")

    # Initialize camera
    camera = CameraCapture(config["camera"])
    logger.info("Camera initialized: source=%s", config["camera"]["source"])

    # Fix 1.6: Shared shutdown event for graceful drain
    shutdown_event = threading.Event()

    # Start sync engine (background thread)
    sync = SyncEngine(
        config["sync"], db,
        models_config=config.get("models", {}),
        shutdown_event=shutdown_event,
    )
    sync_thread = threading.Thread(target=sync.run, daemon=True, name="sync-engine")
    sync_thread.start()
    logger.info("Sync engine started (interval=%ds)", config["sync"]["interval_seconds"])

    # Start health/API server (background thread)
    server_cfg = config["server"]
    server_thread = threading.Thread(
        target=start_health_server,
        args=(server_cfg["host"], server_cfg["port"], db, pool),
        kwargs={
            "api_key": server_cfg.get("api_key", ""),
            "device_id": device_id,
        },
        daemon=True,
    )
    server_thread.start()
    logger.info("Health server started on %s:%d", server_cfg["host"], server_cfg["port"])

    # Graceful shutdown
    running = True

    def handle_signal(signum, _frame):
        nonlocal running
        logger.info("Shutdown signal received (sig=%s)", signum)
        running = False
        shutdown_event.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Main loop — mode and interval from local config (overridden by remote)
    available = pool.available_engines()
    mode = config["camera"].get("mode", "manual")
    interval = config["camera"].get("interval_seconds", 1800)
    default_leaf = available[0]

    logger.info("Starting main loop (mode=%s) — Local-First active", mode)

    # Fix 1.6: try/finally ensures cleanup runs even on uncaught exceptions
    try:
        while running:
            # Check for remote config updates (thread-safe, no network call)
            try:
                remote_cfg = sync.get_active_config()
                if remote_cfg:
                    new_mode = remote_cfg.get("mode", mode)
                    new_interval = remote_cfg.get("interval_seconds", interval)
                    new_leaf = remote_cfg.get("default_leaf_type", default_leaf)
                    if new_mode != mode or new_interval != interval:
                        logger.info(
                            "Config update: mode=%s -> %s, interval=%ds -> %ds",
                            mode, new_mode, interval, new_interval,
                        )
                    mode = new_mode
                    interval = new_interval
                    if new_leaf in available:
                        default_leaf = new_leaf
            except Exception as e:
                logger.warning("Config check failed, keeping current: %s", e)

            if mode == "periodic":
                # Crash-guard: restart sync thread if it died unexpectedly.
                if not sync_thread.is_alive() and not shutdown_event.is_set():
                    logger.error("Sync thread died — restarting")
                    sync_thread = threading.Thread(
                        target=sync.run, daemon=True, name="sync-engine"
                    )
                    sync_thread.start()
                try:
                    # Fix 1.7: Wake-Capture-Sleep — open camera, capture,
                    # release each cycle to reduce heat and sensor wear.
                    frame = camera.capture_single()
                    if frame is not None:
                        # Fix 1.1: Submit to pool (thread-safe, CUDA-owner)
                        result = pool.submit(default_leaf, frame).result(timeout=30)
                        db.save_prediction(default_leaf, result, device_id=device_id)
                        logger.info(
                            "Prediction: %s (%.1f%%)",
                            result["class_name"],
                            result["confidence"] * 100,
                        )
                except Exception as e:
                    logger.error("Capture/inference error: %s", e)
                _notify_watchdog()
                shutdown_event.wait(timeout=interval)
                if shutdown_event.is_set():
                    break
            else:
                # Manual mode — predictions triggered via REST API /predict
                # Crash-guard: restart sync thread if it died unexpectedly.
                if not sync_thread.is_alive() and not shutdown_event.is_set():
                    logger.error("Sync thread died — restarting")
                    sync_thread = threading.Thread(
                        target=sync.run, daemon=True, name="sync-engine"
                    )
                    sync_thread.start()
                _notify_watchdog()
                shutdown_event.wait(timeout=5)
                if shutdown_event.is_set():
                    break
    finally:
        logger.info("AgriKD Jetson Edge Inference - Shutting down")
        # Signal sync engine to drain, then wait briefly
        sync.stop()
        sync_thread.join(timeout=15)
        # Clean up resources
        pool.shutdown()
        camera.release()
        db.close()
        logger.info("AgriKD Jetson Edge Inference - Stopped")


if __name__ == "__main__":
    main()
