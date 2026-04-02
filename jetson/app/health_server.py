"""Health check and REST API server for Jetson edge inference."""

import functools
import logging
import time
from collections import defaultdict
from threading import Lock

import cv2
import numpy as np
from flask import Flask, jsonify, request


logger = logging.getLogger("health")
app = Flask(__name__)

# 10 MB upload limit
app.config["MAX_CONTENT_LENGTH"] = 10 * 1024 * 1024

# Allowed image extensions
_ALLOWED_EXTENSIONS = {"jpg", "jpeg", "png", "bmp", "tiff"}

# These are set when the server starts
_db = None
_engines = None
_start_time = None
_api_key = ""

# Inference lock: serialize GPU access across waitress threads
_inference_lock = Lock()
_prediction_count = 0


# ── API Key Authorization (Zero-Trust for LAN) ──
@app.before_request
def _check_api_key():
    """Require X-API-Key header on all endpoints except /health."""
    if request.endpoint == "health":
        return  # Health check is unauthenticated
    if _api_key and request.headers.get("X-API-Key") != _api_key:
        return jsonify({"error": "Unauthorized"}), 401

# ── Simple in-memory rate limiter (no external deps) ──
_rate_lock = Lock()
_rate_buckets = defaultdict(list)  # ip -> [timestamps]
_last_rate_cleanup = 0.0


def _do_rate_cleanup(cutoff):
    """Remove stale IPs from rate buckets (every 60s, must hold _rate_lock)."""
    global _last_rate_cleanup
    now = time.time()
    if now - _last_rate_cleanup < 60:
        return
    _last_rate_cleanup = now
    stale = [k for k, v in _rate_buckets.items() if not v or v[-1] < cutoff]
    for k in stale:
        del _rate_buckets[k]


def rate_limit(max_per_minute=30):
    """Decorator: limit requests per IP per minute."""

    def decorator(f):
        @functools.wraps(f)
        def wrapper(*args, **kwargs):
            ip = request.remote_addr or "unknown"
            now = time.time()
            cutoff = now - 60

            with _rate_lock:
                # Prune old timestamps for this IP
                _rate_buckets[ip] = [
                    t for t in _rate_buckets[ip] if t > cutoff
                ]
                if len(_rate_buckets[ip]) >= max_per_minute:
                    return jsonify({
                        "error": f"Rate limit exceeded ({max_per_minute} req/min)",
                    }), 429
                _rate_buckets[ip].append(now)

                # Periodic cleanup: remove stale IPs every 60 seconds
                _do_rate_cleanup(cutoff)

            return f(*args, **kwargs)

        return wrapper

    return decorator


def _allowed_file(filename):
    """Check if file extension is in the allowed set."""
    if not filename or "." not in filename:
        return False
    ext = filename.rsplit(".", 1)[1].lower()
    return ext in _ALLOWED_EXTENSIONS


@app.errorhandler(413)
def request_entity_too_large(error):
    return jsonify({"error": "File too large (max 10 MB)"}), 413


@app.route("/health")
@rate_limit(max_per_minute=30)
def health():
    """Health check endpoint."""
    uptime = time.time() - _start_time if _start_time else 0
    stats = _db.get_stats() if _db else {}
    return jsonify({
        "status": "healthy",
        "uptime_seconds": int(uptime),
        "models_loaded": list(_engines.keys()) if _engines else [],
        "database": stats,
    })


@app.route("/predict", methods=["POST"])
@rate_limit(max_per_minute=30)
def predict():
    """Run inference on an uploaded image.

    Accept multipart/form-data with:
    - image: JPEG/PNG file (max 10 MB)
    - leaf_type: string (default: first available model)
    """
    global _prediction_count

    # H3: Guard — no engines loaded
    if not _engines:
        return jsonify({"error": "No models loaded"}), 503

    if "image" not in request.files:
        return jsonify({"error": "No image file provided"}), 400

    file = request.files["image"]

    # Validate file extension
    if not _allowed_file(file.filename):
        return jsonify({
            "error": "Invalid file type. Allowed: jpg, jpeg, png, bmp, tiff",
        }), 400

    leaf_type = request.form.get("leaf_type", list(_engines.keys())[0])
    if leaf_type not in _engines:
        return jsonify({
            "error": f"Unknown leaf type: {leaf_type}",
            "available": list(_engines.keys()),
        }), 400

    try:
        file_bytes = np.frombuffer(file.read(), np.uint8)
        frame = cv2.imdecode(file_bytes, cv2.IMREAD_COLOR)

        if frame is None:
            return jsonify({"error": "Invalid image file"}), 400

        engine = _engines[leaf_type]

        # C3: Serialize GPU access across waitress threads
        with _inference_lock:
            result = engine.predict(frame)

        # Save to DB
        _db.save_prediction(leaf_type, result)

        # M4: Throttle cleanup to every 100 predictions
        _prediction_count += 1
        if _prediction_count % 100 == 0:
            _db.cleanup_old_records()

        return jsonify({
            "leaf_type": leaf_type,
            "prediction": result,
        })
    except Exception as e:
        app.logger.error(f"Prediction failed: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/stats")
@rate_limit(max_per_minute=30)
def stats():
    """Get prediction statistics."""
    return jsonify(_db.get_stats() if _db else {})


def start_health_server(host, port, db, engines, api_key=""):
    """Start the Flask health/API server."""
    global _db, _engines, _start_time, _api_key
    _db = db
    _engines = engines
    _start_time = time.time()
    _api_key = api_key

    if not _api_key:
        logger.warning(
            "No API key configured — all endpoints are unauthenticated"
        )

    from waitress import serve

    serve(app, host=host, port=port, threads=4)
