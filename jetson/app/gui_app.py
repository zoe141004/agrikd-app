"""
AgriKD Jetson GUI Application
==============================
Desktop GUI for plant leaf disease inference on NVIDIA Jetson.

Uses PyQt5 for UI, reuses existing inference/camera/database modules.
Supports live camera preview, file picker, model selection, and
saves images for Active Learning.

Usage:
    python3 gui_app.py [--config config/config.json]
"""

import argparse
import json
import logging
import os
import shutil
import sys
import time
from datetime import datetime
from logging.handlers import RotatingFileHandler

import cv2
import numpy as np
from PyQt5.QtCore import Qt, QThread, pyqtSignal, QTimer
from PyQt5.QtGui import QFont, QImage, QPixmap
from PyQt5.QtWidgets import (
    QApplication,
    QComboBox,
    QFileDialog,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSplitter,
    QStatusBar,
    QTableWidget,
    QTableWidgetItem,
    QToolBar,
    QVBoxLayout,
    QWidget,
)

from camera import CameraCapture
from database import JetsonDatabase
from inference import InferenceWorkerPool

# ---------------------------------------------------------------------------
# Logging (deferred — file handler added after CWD is resolved in main())
# ---------------------------------------------------------------------------

logger = logging.getLogger("agrikd_gui")


def _setup_logging():
    """Configure file logging. Must be called AFTER os.chdir()."""
    log_dir = "logs"
    os.makedirs(log_dir, exist_ok=True)
    logger.setLevel(logging.INFO)
    handler = RotatingFileHandler(
        os.path.join(log_dir, "agrikd_gui.log"),
        maxBytes=100 * 1024 * 1024,  # 100 MB
        backupCount=5,
    )
    handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    )
    logger.addHandler(handler)
    logger.addHandler(logging.StreamHandler(sys.stdout))

# ---------------------------------------------------------------------------
# Worker threads
# ---------------------------------------------------------------------------


class CameraThread(QThread):
    """Continuously capture frames from camera in background thread."""

    frame_ready = pyqtSignal(np.ndarray)
    error = pyqtSignal(str)

    def __init__(self, camera):
        super().__init__()
        self.camera = camera
        self._running = False

    def run(self):
        self._running = True
        logger.info("Camera thread started")
        retry_count = 0
        max_retries = 3
        while self._running:
            frame = self.camera.capture()
            if frame is not None:
                retry_count = 0  # Reset on successful capture
                self.frame_ready.emit(frame)
            else:
                retry_count += 1
                logger.warning(
                    "Camera capture failed (attempt %d/%d)",
                    retry_count,
                    max_retries,
                )
                if retry_count >= max_retries:
                    self.error.emit("Camera capture failed after 3 retries")
                    logger.error("Camera capture returned None %d times, giving up", max_retries)
                    break
                self.msleep(1000)  # 1-second backoff before retry
                continue
            self.msleep(33)  # ~30 FPS
        logger.info("Camera thread stopped")

    def stop(self):
        self._running = False
        self.wait(3000)


class InferenceBridge(QThread):
    """Bridge between Qt UI and InferenceWorkerPool.

    Submits a job to the pool (which owns the CUDA context on its own
    thread) and emits Qt signals when the result is ready.  This avoids
    CUDA context-affinity violations (C1) and shared-buffer races (C2).
    """

    result_ready = pyqtSignal(dict)
    error = pyqtSignal(str)

    def __init__(self, pool, leaf_type, frame):
        super().__init__()
        self._pool = pool
        self.leaf_type = leaf_type
        self.frame = frame.copy()

    def run(self):
        try:
            future = self._pool.submit(self.leaf_type, self.frame)
            result = future.result(timeout=30)
            result["leaf_type"] = self.leaf_type
            self.result_ready.emit(result)
        except Exception as e:
            logger.exception("Inference error")
            self.error.emit(str(e))


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------


class MainWindow(QMainWindow):
    def __init__(self, config):
        super().__init__()
        self.config = config
        self.setWindowTitle("AgriKD — Plant Disease Detection")
        self.setMinimumSize(1080, 640)

        # State
        self._pool = None
        self.current_frame = None
        self.camera_thread = None
        self._inference_bridge = None
        self._prediction_count = 0

        # Modules
        self.camera = CameraCapture(config["camera"])
        self.db = JetsonDatabase(config["database"]["path"])

        # Active Learning image dir
        self.image_base = os.path.join("data", "images")
        os.makedirs(self.image_base, exist_ok=True)

        self._init_pool()
        self._build_ui()
        self._update_status()

        # Auto-refresh status bar every 30 seconds
        self._status_timer = QTimer()
        self._status_timer.timeout.connect(self._update_status)
        self._status_timer.start(30000)

        loaded = self._pool.available_engines() if self._pool else []
        logger.info("GUI initialized — %d engines loaded", len(loaded))

    # ── Engine loading (via InferenceWorkerPool) ─────────────────────

    def _init_pool(self):
        """Initialize InferenceWorkerPool — engines load on the pool's
        dedicated CUDA thread, avoiding context-affinity issues (C1)."""
        try:
            self._pool = InferenceWorkerPool(
                self.config["models"],
                inference_config=self.config.get("inference", {}),
            )
        except RuntimeError as e:
            logger.error("Failed to initialize inference pool: %s", e)
            self._pool = None

    # ── UI construction ────────────────────────────────────────────────

    def _build_ui(self):
        # -- Toolbar --
        toolbar = QToolBar("Main")
        toolbar.setMovable(False)
        self.addToolBar(toolbar)

        toolbar.addWidget(QLabel("  Model: "))
        self.model_selector = QComboBox()
        self.model_selector.setMinimumWidth(200)
        for leaf_type in self.config["models"]:
            display = leaf_type.replace("_", " ").title()
            self.model_selector.addItem(display, leaf_type)
        toolbar.addWidget(self.model_selector)
        toolbar.addSeparator()

        self.btn_camera = QPushButton("Start Camera")
        self.btn_camera.setCheckable(True)
        self.btn_camera.clicked.connect(self._toggle_camera)
        toolbar.addWidget(self.btn_camera)

        # -- Central widget --
        central = QWidget()
        self.setCentralWidget(central)

        splitter = QSplitter(Qt.Horizontal)
        layout = QHBoxLayout(central)
        layout.addWidget(splitter)

        # Left panel: preview + buttons
        left = QWidget()
        left_layout = QVBoxLayout(left)

        self.preview_label = QLabel("Camera preview")
        self.preview_label.setAlignment(Qt.AlignCenter)
        self.preview_label.setMinimumSize(480, 360)
        self.preview_label.setStyleSheet(
            "background-color: #1a1a2e; color: #aaa; font-size: 14px; border: 1px solid #333;"
        )
        left_layout.addWidget(self.preview_label, stretch=1)

        btn_row = QHBoxLayout()
        self.btn_capture = QPushButton("Capture && Analyze")
        self.btn_capture.setMinimumHeight(40)
        self.btn_capture.clicked.connect(self._on_capture)
        btn_row.addWidget(self.btn_capture)

        self.btn_file = QPushButton("Load Image File")
        self.btn_file.setMinimumHeight(40)
        self.btn_file.clicked.connect(self._on_load_file)
        btn_row.addWidget(self.btn_file)
        left_layout.addLayout(btn_row)

        splitter.addWidget(left)

        # Right panel: results
        right = QWidget()
        right_layout = QVBoxLayout(right)

        title = QLabel("Results")
        title.setFont(QFont("", 14, QFont.Bold))
        right_layout.addWidget(title)

        self.result_class = QLabel("—")
        self.result_class.setFont(QFont("", 22, QFont.Bold))
        self.result_class.setStyleSheet("color: #16a34a;")
        right_layout.addWidget(self.result_class)

        self.result_confidence = QLabel("Confidence: —")
        self.result_confidence.setFont(QFont("", 14))
        right_layout.addWidget(self.result_confidence)

        self.result_time = QLabel("Inference: —")
        self.result_time.setFont(QFont("", 11))
        self.result_time.setStyleSheet("color: #888;")
        right_layout.addWidget(self.result_time)

        right_layout.addSpacing(10)

        table_label = QLabel("All Classes")
        table_label.setFont(QFont("", 11, QFont.Bold))
        right_layout.addWidget(table_label)

        self.conf_table = QTableWidget(0, 2)
        self.conf_table.setHorizontalHeaderLabels(["Class", "Confidence"])
        self.conf_table.horizontalHeader().setSectionResizeMode(
            0, QHeaderView.Stretch
        )
        self.conf_table.horizontalHeader().setSectionResizeMode(
            1, QHeaderView.ResizeToContents
        )
        self.conf_table.setEditTriggers(QTableWidget.NoEditTriggers)
        right_layout.addWidget(self.conf_table, stretch=1)

        self.analyzed_preview = QLabel()
        self.analyzed_preview.setAlignment(Qt.AlignCenter)
        self.analyzed_preview.setFixedHeight(120)
        right_layout.addWidget(self.analyzed_preview)

        splitter.addWidget(right)
        splitter.setSizes([600, 400])

        # -- Status bar --
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)

    # ── Camera ─────────────────────────────────────────────────────────

    def _toggle_camera(self, checked):
        if checked:
            self._start_camera()
        else:
            self._stop_camera()

    def _start_camera(self):
        self.camera_thread = CameraThread(self.camera)
        self.camera_thread.frame_ready.connect(self._on_frame)
        self.camera_thread.error.connect(self._on_camera_error)
        self.camera_thread.start()
        self.btn_camera.setText("Stop Camera")
        logger.info("Camera started")

    def _stop_camera(self):
        if self.camera_thread is not None:
            self.camera_thread.stop()
            self.camera_thread = None
        self.camera.release()
        self.btn_camera.setText("Start Camera")
        self.btn_camera.setChecked(False)
        logger.info("Camera stopped")

    def _on_frame(self, frame):
        self.current_frame = frame
        self._display_frame(frame, self.preview_label)

    def _on_camera_error(self, msg):
        self._stop_camera()
        self.status_bar.showMessage(f"Camera error: {msg}", 5000)
        logger.error("Camera error: %s", msg)

    # ── Inference ──────────────────────────────────────────────────────

    def _on_capture(self):
        if self.current_frame is None:
            QMessageBox.information(
                self, "No Frame", "Start the camera or load an image first."
            )
            return
        self._run_inference(self.current_frame)

    def _on_load_file(self):
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Select Leaf Image",
            "",
            "Images (*.jpg *.jpeg *.png *.bmp *.tiff)",
        )
        if not path:
            return
        frame = cv2.imread(path)
        if frame is None:
            QMessageBox.warning(self, "Error", f"Cannot read image:\n{path}")
            return
        self.current_frame = frame
        self._display_frame(frame, self.preview_label)
        self._run_inference(frame)

    def _run_inference(self, frame):
        # C2: Prevent concurrent inference (guard against rapid clicks)
        if self._inference_bridge and self._inference_bridge.isRunning():
            return

        leaf_type = self.model_selector.currentData()
        if self._pool is None:
            QMessageBox.warning(
                self,
                "No Engine",
                "TensorRT inference is not available.\n"
                "Check CUDA/TensorRT installation on this device.",
            )
            return
        available = self._pool.available_engines()
        if leaf_type not in available:
            QMessageBox.warning(
                self,
                "No Engine",
                f"TensorRT engine for '{leaf_type}' not loaded.\n"
                "Check that the .engine file exists and was built for this device.",
            )
            return
        self.btn_capture.setEnabled(False)
        self.btn_file.setEnabled(False)
        self.status_bar.showMessage("Running inference...")

        self._inference_bridge = InferenceBridge(self._pool, leaf_type, frame)
        self._inference_bridge.result_ready.connect(self._on_result)
        self._inference_bridge.error.connect(self._on_inference_error)
        self._inference_bridge.start()

    def _on_result(self, result):
        self.btn_capture.setEnabled(True)
        self.btn_file.setEnabled(True)

        leaf_type = result["leaf_type"]
        class_name = result["class_name"]
        confidence = result["confidence"]
        time_ms = result["inference_time_ms"]

        # Display results
        self.result_class.setText(class_name.replace("_", " "))
        self.result_confidence.setText(f"Confidence: {confidence * 100:.1f}%")
        self.result_time.setText(f"Inference: {time_ms:.2f} ms")

        # Fill confidence table
        labels = self.config["models"][leaf_type]["class_labels"]
        all_conf = result.get("all_confidences", [])
        self.conf_table.setRowCount(len(labels))
        for i, (label, conf) in enumerate(zip(labels, all_conf)):
            self.conf_table.setItem(i, 0, QTableWidgetItem(label.replace("_", " ")))
            item = QTableWidgetItem(f"{conf * 100:.1f}%")
            item.setTextAlignment(Qt.AlignRight | Qt.AlignVCenter)
            self.conf_table.setItem(i, 1, item)

        # Show analyzed image thumbnail
        # Fix 1.4: Use the inference bridge's frozen frame copy, NOT
        # self.current_frame which may have advanced during inference
        analyzed_frame = self._inference_bridge.frame
        if analyzed_frame is not None:
            self._display_frame(analyzed_frame, self.analyzed_preview)

        # Active Learning: save the actually-analyzed frame
        image_path = self._save_image(leaf_type, analyzed_frame)

        # Save to database
        self.db.save_prediction(leaf_type, result, image_path=image_path)

        # M9: Throttle cleanup to every 50 predictions
        self._prediction_count += 1
        if self._prediction_count % 50 == 0:
            self.db.cleanup_old_records()

        self._update_status()

        logger.info(
            "Prediction: %s/%s confidence=%.3f time=%.2fms image=%s",
            leaf_type,
            class_name,
            confidence,
            time_ms,
            image_path,
        )

    def _on_inference_error(self, msg):
        self.btn_capture.setEnabled(True)
        self.btn_file.setEnabled(True)
        self.status_bar.showMessage(f"Inference error: {msg}", 5000)
        QMessageBox.critical(self, "Inference Error", msg)

    # ── Active Learning: image saving ──────────────────────────────────

    def _save_image(self, leaf_type, frame):
        """Save captured frame for Active Learning data collection."""
        save_dir = os.path.join(self.image_base, leaf_type)
        os.makedirs(save_dir, exist_ok=True)

        # Disk space check before saving
        disk = shutil.disk_usage(save_dir)
        if disk.free < 500 * 1024 * 1024:  # 500 MB minimum
            logger.warning("Low disk space (%.0f MB free), skipping image save", disk.free / 1024 / 1024)
            return None

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        filename = f"{timestamp}.jpg"
        filepath = os.path.join(save_dir, filename)
        ok = cv2.imwrite(filepath, frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
        if not ok:
            logger.warning("cv2.imwrite failed for %s", filepath)
            return None
        return filepath

    # ── Helpers ────────────────────────────────────────────────────────

    def _display_frame(self, frame, label):
        """Convert OpenCV BGR frame to QPixmap and display on a QLabel."""
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        h, w, ch = rgb.shape
        img = QImage(rgb.data, w, h, ch * w, QImage.Format_RGB888)
        pixmap = QPixmap.fromImage(img).scaled(
            label.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation
        )
        label.setPixmap(pixmap)

    def _update_status(self):
        stats = self.db.get_stats()
        models_loaded = ", ".join(self._pool.available_engines()) if self._pool else "none"
        device_status = self._get_device_status()
        self.status_bar.showMessage(
            f"{device_status}  |  "
            f"Models: {models_loaded}  |  "
            f"Predictions: {stats['total_predictions']}  |  "
            f"Unsynced: {stats['unsynced']}"
        )

    def _get_device_status(self):
        """Read device state (READ-ONLY) and return status string.

        Correction C: Uses shared file lock for safe reading.
        Correction D: Compares desired_config vs reported_config for
        pending status detection.
        Fix 1.8: Retry once after 50ms for atomic-replace window safety.
        """
        state_path = os.path.join("data", "device_state.json")
        for attempt in range(2):
            try:
                with open(state_path, "r") as f:
                    # Shared lock for read-only access (sync_engine is single writer)
                    try:
                        import fcntl
                        fcntl.flock(f, fcntl.LOCK_SH)
                    except ImportError:
                        pass  # Windows dev: no fcntl
                    try:
                        state = json.load(f)
                    finally:
                        try:
                            import fcntl
                            fcntl.flock(f, fcntl.LOCK_UN)
                        except ImportError:  # fcntl unavailable on Windows
                            pass

                    if state.get("user_id"):
                        # Correction D: check if config is pending
                        desired = state.get("desired_config")
                        reported = state.get("reported_config")
                        if desired and desired != reported:
                            return "Device: Online (config pending)"
                        return "Device: Online (syncing)"
                    return "Device: Registered (waiting for assignment)"
            except (FileNotFoundError, json.JSONDecodeError, OSError):
                if attempt == 0:
                    time.sleep(0.05)
        return "Device: Standalone (local only)"

    def closeEvent(self, event):
        self._stop_camera()
        if self._pool:
            self._pool.shutdown()
        self.db.close()
        logger.info("GUI closed")
        event.accept()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def _ensure_system_python():
    """Verify TensorRT is importable; re-exec with system Python if needed.

    JetPack installs TensorRT for the system Python only.  When the user
    launches the GUI from a conda or virtualenv environment, ``import
    tensorrt`` will fail.  Instead of printing a cryptic error, detect the
    situation and transparently re-launch with ``/usr/bin/python3``.
    """
    try:
        import tensorrt  # noqa: F401
        return  # TensorRT available — nothing to do
    except ImportError:
        pass

    in_conda = os.environ.get("CONDA_PREFIX") or os.environ.get("CONDA_DEFAULT_ENV")
    in_venv = sys.prefix != sys.base_prefix
    system_python = "/usr/bin/python3"

    if (in_conda or in_venv) and os.path.isfile(system_python):
        env_name = (
            os.environ.get("CONDA_DEFAULT_ENV", "conda")
            if in_conda
            else os.path.basename(sys.prefix)
        )
        print(
            f"\n[INFO] TensorRT not found in current Python ({sys.executable})."
            f"\n  Detected environment: {env_name}"
            f"\n  TensorRT is provided by JetPack and only available in system Python."
            f"\n  Re-launching with {system_python} ...\n"
        )
        os.execv(system_python, [system_python] + sys.argv)
        # execv never returns
    else:
        print(
            f"\n[ERROR] TensorRT is not installed."
            f"\n  Current Python: {sys.executable}"
            f"\n  Install JetPack SDK or run with system Python:"
            f"\n    /usr/bin/python3 {' '.join(sys.argv)}\n"
        )
        sys.exit(1)


def main():
    _ensure_system_python()

    # Resolve working directory to install root so relative paths
    # in config (models/, config/, data/) resolve correctly.
    # Typical layout: /opt/agrikd/app/gui_app.py → use parent /opt/agrikd/
    # Fallback:       if config/ is next to script → use script dir
    script_dir = os.path.dirname(os.path.abspath(__file__))
    if os.path.isdir(os.path.join(script_dir, "config")):
        install_root = script_dir
    else:
        install_root = os.path.dirname(script_dir)
    os.chdir(install_root)
    _setup_logging()

    parser = argparse.ArgumentParser(description="AgriKD Jetson GUI")
    parser.add_argument(
        "--config",
        default="config/config.json",
        help="Path to config.json (default: config/config.json)",
    )
    args = parser.parse_args()

    # Load config
    config_path = args.config
    if not os.path.exists(config_path):
        print(f"[ERROR] Config not found: {config_path}")
        sys.exit(1)

    with open(config_path, "r") as f:
        config = json.load(f)

    # H2: Basic config validation
    for section in ("camera", "models", "database"):
        if section not in config:
            print(f"[ERROR] Config missing required section: '{section}'")
            sys.exit(1)
    if not config["models"]:
        print("[ERROR] Config 'models' section is empty")
        sys.exit(1)

    print(f"Starting AgriKD GUI with config: {config_path}")
    print(f"Working directory: {os.getcwd()}")
    logger.info("Starting AgriKD GUI with config: %s (cwd: %s)", config_path, os.getcwd())

    app = QApplication(sys.argv)
    app.setApplicationName("AgriKD")

    window = MainWindow(config)
    window.show()

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
