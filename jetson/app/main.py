"""
AgriKD Jetson Edge Inference Application
=========================================
Main entry point for running plant disease inference on NVIDIA Jetson devices.

Features:
- TensorRT FP16 inference (~1-2ms per image)
- USB/CSI camera capture with OpenCV
- SQLite local database (WAL mode)
- HTTP sync to Supabase
- REST API health check endpoint (/health, /predict)
"""

import json
import logging
import os
import signal
import sys
import threading
import time

from camera import CameraCapture
from database import JetsonDatabase
from health_server import start_health_server
from inference import TensorRTInference
from sync_engine import SyncEngine


def setup_logging(config):
    """Configure logging with rotation."""
    log_cfg = config.get("logging", {})
    log_file = log_cfg.get("file", "logs/agrikd.log")
    os.makedirs(os.path.dirname(log_file), exist_ok=True)

    from logging.handlers import RotatingFileHandler

    handler = RotatingFileHandler(
        log_file,
        maxBytes=log_cfg.get("max_bytes", 100 * 1024 * 1024),
        backupCount=log_cfg.get("backup_count", 5),
    )
    handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    )

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_cfg.get("level", "INFO")))
    root.addHandler(handler)
    root.addHandler(logging.StreamHandler(sys.stdout))


def load_config(path="config/config.json"):
    """Load configuration from JSON file."""
    with open(path, "r") as f:
        return json.load(f)


def main():
    config = load_config()
    setup_logging(config)
    logger = logging.getLogger("main")

    logger.info("=" * 50)
    logger.info("AgriKD Jetson Edge Inference - Starting")
    logger.info("=" * 50)

    # Initialize database (WAL mode for concurrent access)
    db = JetsonDatabase(config["database"]["path"])
    logger.info("Database initialized: %s", config["database"]["path"])

    # Load TensorRT engines
    engines = {}
    inference_cfg = config.get("inference", {})
    for leaf_type, model_cfg in config["models"].items():
        engine_path = model_cfg["engine_path"]
        if os.path.exists(engine_path):
            engines[leaf_type] = TensorRTInference(
                engine_path, model_cfg,
                expected_sha256=model_cfg.get("sha256_checksum"),
                inference_config=inference_cfg,
            )
            logger.info("Loaded TensorRT engine: %s (%s)", leaf_type, engine_path)
        else:
            logger.warning("Engine not found: %s — skipping %s", engine_path, leaf_type)

    if not engines:
        logger.error("No TensorRT engines loaded. Exiting.")
        sys.exit(1)

    # Initialize camera
    camera = CameraCapture(config["camera"])
    logger.info("Camera initialized: source=%s", config["camera"]["source"])

    # Start sync engine (background thread)
    sync = SyncEngine(config["sync"], db, models_config=config.get("models", {}))
    sync_thread = threading.Thread(target=sync.run, daemon=True)
    sync_thread.start()
    logger.info("Sync engine started (interval=%ds)", config["sync"]["interval_seconds"])

    # Start health/API server (background thread)
    server_cfg = config["server"]
    server_thread = threading.Thread(
        target=start_health_server,
        args=(server_cfg["host"], server_cfg["port"], db, engines),
        kwargs={"api_key": server_cfg.get("api_key", "")},
        daemon=True,
    )
    server_thread.start()
    logger.info("Health server started on %s:%d", server_cfg["host"], server_cfg["port"])

    # Graceful shutdown
    running = True

    def handle_signal(signum, frame):
        nonlocal running
        logger.info("Shutdown signal received")
        running = False

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Main loop — manual mode: wait for API trigger
    # Periodic mode: capture at configured interval
    mode = config["camera"].get("mode", "manual")
    default_leaf = list(engines.keys())[0]

    if mode == "periodic":
        interval = config["camera"].get("interval_seconds", 1800)
        logger.info("Periodic mode: capturing every %d seconds", interval)
        while running:
            try:
                frame = camera.capture()
                if frame is not None:
                    engine = engines[default_leaf]
                    result = engine.predict(frame)
                    db.save_prediction(default_leaf, result)
                    logger.info(
                        "Prediction: %s (%.1f%%)",
                        result["class_name"],
                        result["confidence"] * 100,
                    )
            except Exception as e:
                logger.error("Capture/inference error: %s", e)
            time.sleep(interval)
    else:
        # Manual mode — predictions triggered via REST API /predict
        logger.info("Manual mode: waiting for API triggers on /predict")
        while running:
            time.sleep(1)

    logger.info("AgriKD Jetson Edge Inference - Stopped")
    camera.release()
    db.close()


if __name__ == "__main__":
    main()
