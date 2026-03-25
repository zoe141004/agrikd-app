"""Health check and REST API server for Jetson edge inference."""

import json
import logging
import time
import traceback

from flask import Flask, jsonify, request
import cv2
import numpy as np


logger = logging.getLogger("health")
app = Flask(__name__)

# These are set when the server starts
_db = None
_engines = None
_start_time = None


@app.route("/health")
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
def predict():
    """Run inference on an uploaded image.

    Accept multipart/form-data with:
    - image: JPEG/PNG file
    - leaf_type: string (default: first available model)
    """
    if "image" not in request.files:
        return jsonify({"error": "No image file provided"}), 400

    leaf_type = request.form.get("leaf_type", list(_engines.keys())[0])
    if leaf_type not in _engines:
        return jsonify({
            "error": f"Unknown leaf type: {leaf_type}",
            "available": list(_engines.keys()),
        }), 400

    try:
        file = request.files["image"]
        file_bytes = np.frombuffer(file.read(), np.uint8)
        frame = cv2.imdecode(file_bytes, cv2.IMREAD_COLOR)

        if frame is None:
            return jsonify({"error": "Invalid image file"}), 400

        engine = _engines[leaf_type]
        result = engine.predict(frame)

        # Save to DB
        _db.save_prediction(leaf_type, result)

        return jsonify({
            "leaf_type": leaf_type,
            "prediction": result,
        })
    except Exception as e:
        logger.error("Prediction error: %s\n%s", e, traceback.format_exc())
        return jsonify({"error": str(e)}), 500


@app.route("/stats")
def stats():
    """Get prediction statistics."""
    return jsonify(_db.get_stats() if _db else {})


def start_health_server(host, port, db, engines):
    """Start the Flask health/API server."""
    global _db, _engines, _start_time
    _db = db
    _engines = engines
    _start_time = time.time()

    # Suppress Flask request logging in production
    logging.getLogger("werkzeug").setLevel(logging.WARNING)

    app.run(host=host, port=port, threaded=True)
