"""Health check and REST API server for Jetson edge inference."""

import functools
import hmac
import logging
import os
import secrets
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
_pool = None          # InferenceWorkerPool (replaces old _engines dict)
_start_time = None
_api_key = ""
_device_id = None     # Fix 2.8: trace API predictions to device
_prediction_count = 0


# ── API Key Authorization (Zero-Trust for LAN) ──
@app.before_request
def _check_api_key():
    """Require X-API-Key header on all endpoints except /health."""
    if request.endpoint == "health":
        return None  # Health check is unauthenticated
    # Fix 1.5: Always require key (no more empty-string bypass).
    # Timing-safe comparison via hmac.compare_digest.
    provided = request.headers.get("X-API-Key", "")
    if not hmac.compare_digest(provided, _api_key):
        return jsonify({"error": "Unauthorized"}), 401
    return None


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
    """Health check endpoint.

    Returns minimal info for unauthenticated requests (liveness probe).
    Detailed info requires valid API key via X-API-Key header.
    """
    # Minimal liveness response (always unauthenticated)
    resp = {"status": "healthy"}

    # If valid API key provided, include detailed diagnostics
    provided = request.headers.get("X-API-Key", "")
    if _api_key and hmac.compare_digest(provided, _api_key):
        uptime = time.time() - _start_time if _start_time else 0
        stats = _db.get_stats() if _db else {}
        resp.update({
            "uptime_seconds": int(uptime),
            "models_loaded": _pool.available_engines() if _pool else [],
            "database": stats,
        })

    return jsonify(resp)


@app.route("/predict", methods=["POST"])
@rate_limit(max_per_minute=30)
def predict():
    """Run inference on an uploaded image.

    Accept multipart/form-data with:
    - image: JPEG/PNG file (max 10 MB)
    - leaf_type: string (default: first available model)
    """
    global _prediction_count

    if not _pool:
        return jsonify({"error": "No models loaded"}), 503

    available = _pool.available_engines()
    if not available:
        return jsonify({"error": "No models loaded"}), 503

    if "image" not in request.files:
        return jsonify({"error": "No image file provided"}), 400

    file = request.files["image"]

    # Validate file extension
    if not _allowed_file(file.filename):
        return jsonify({
            "error": "Invalid file type. Allowed: jpg, jpeg, png, bmp, tiff",
        }), 400

    leaf_type = request.form.get("leaf_type", available[0])
    if leaf_type not in available:
        return jsonify({
            "error": f"Unknown leaf type: {leaf_type}",
            "available": available,
        }), 400

    try:
        raw = file.read()

        # Magic-bytes check: JPEG (FFD8FF), PNG (89504E47), BMP (424D), TIFF (4949/4D4D)
        if len(raw) < 4:
            return jsonify({"error": "File too small to be a valid image"}), 400
        header = raw[:4]
        valid_magic = (
            header[:3] == b"\xff\xd8\xff"        # JPEG
            or header[:4] == b"\x89PNG"           # PNG
            or header[:2] == b"BM"                # BMP
            or header[:2] in (b"II", b"MM")       # TIFF
        )
        if not valid_magic:
            return jsonify({"error": "File content does not match a supported image format"}), 400

        file_bytes = np.frombuffer(raw, np.uint8)
        frame = cv2.imdecode(file_bytes, cv2.IMREAD_COLOR)

        if frame is None:
            return jsonify({"error": "Invalid image file"}), 400

        # Reject excessively large images (prevent OOM)
        h, w = frame.shape[:2]
        if h > 4096 or w > 4096:
            return jsonify({"error": f"Image too large ({w}x{h}), max 4096x4096"}), 400

        # Fix 1.1: Submit to InferenceWorkerPool (thread-safe, CUDA-owner)
        result = _pool.submit(leaf_type, frame).result(timeout=30)

        # Fix 2.8: Pass device_id so API predictions are traceable
        _db.save_prediction(leaf_type, result, device_id=_device_id)

        # M4: Throttle cleanup to every 100 predictions
        _prediction_count += 1
        if _prediction_count % 100 == 0:
            _db.cleanup_old_records()

        return jsonify({
            "leaf_type": leaf_type,
            "prediction": result,
        })
    except Exception as e:
        app.logger.error("Prediction failed: %s", e)
        return jsonify({"error": "Internal server error"}), 500


@app.route("/stats")
@rate_limit(max_per_minute=30)
def stats():
    """Get prediction statistics."""
    return jsonify(_db.get_stats() if _db else {})


def start_health_server(host, port, db, pool, api_key="", device_id=None):
    """Start the Flask health/API server.

    Args:
        pool: InferenceWorkerPool instance (thread-safe).
    """
    global _db, _pool, _start_time, _api_key, _device_id
    _db = db
    _pool = pool
    _start_time = time.time()
    _device_id = device_id

    # Fix 1.5: If no api_key configured, auto-generate an ephemeral one.
    # Stored in-memory only — never written to config.json.
    if api_key:
        _api_key = api_key
    else:
        _api_key = secrets.token_hex(16)
        masked = _api_key[:4] + "***" + _api_key[-4:]
        logger.warning(
            "No API key in config — generated ephemeral key: %s", masked,
        )
        # Write full key to a local file (not logged) so operator can retrieve it.
        _key_path = os.path.join(os.path.dirname(__file__), "..", "data", "ephemeral_api_key")
        try:
            os.makedirs(os.path.dirname(_key_path), exist_ok=True)
            with open(_key_path, "w") as _kf:
                _kf.write(_api_key)
            os.chmod(_key_path, 0o600)
        except OSError:
            pass
        print(f"\n*** Ephemeral API key written to data/ephemeral_api_key ({masked}) ***\n")

    from waitress import serve

    serve(app, host=host, port=port, threads=4)
