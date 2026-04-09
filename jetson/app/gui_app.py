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
from inference import TensorRTInference

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOG_DIR = "logs"
os.makedirs(LOG_DIR, exist_ok=True)

logger = logging.getLogger("agrikd_gui")
logger.setLevel(logging.INFO)
_handler = RotatingFileHandler(
    os.path.join(LOG_DIR, "agrikd_gui.log"),
    maxBytes=100 * 1024 * 1024,  # 100 MB
    backupCount=5,
)
_handler.setFormatter(
    logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
)
logger.addHandler(_handler)
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


class InferenceWorker(QThread):
    """Run TensorRT inference in a background thread."""

    result_ready = pyqtSignal(dict)
    error = pyqtSignal(str)

    def __init__(self, engine, frame, leaf_type):
        super().__init__()
        self.engine = engine
        self.frame = frame.copy()
        self.leaf_type = leaf_type

    def run(self):
        try:
            result = self.engine.predict(self.frame)
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
        self.engines = {}
        self.current_frame = None
        self.camera_thread = None
        self._inference_worker = None

        # Modules
        self.camera = CameraCapture(config["camera"])
        self.db = JetsonDatabase(config["database"]["path"])

        # Active Learning image dir
        self.image_base = os.path.join("data", "images")
        os.makedirs(self.image_base, exist_ok=True)

        self._load_engines()
        self._build_ui()
        self._update_status()

        # Auto-refresh status bar every 30 seconds
        self._status_timer = QTimer()
        self._status_timer.timeout.connect(self._update_status)
        self._status_timer.start(30000)

        logger.info("GUI initialized — %d engines loaded", len(self.engines))

    # ── Engine loading ─────────────────────────────────────────────────

    def _load_engines(self):
        inference_cfg = self.config.get("inference", {})
        for leaf_type, model_cfg in self.config["models"].items():
            engine_path = model_cfg["engine_path"]
            if os.path.exists(engine_path):
                try:
                    self.engines[leaf_type] = TensorRTInference(
                        engine_path, model_cfg,
                        expected_sha256=model_cfg.get("sha256_checksum"),
                        inference_config=inference_cfg,
                    )
                    logger.info("Loaded engine: %s (%s)", leaf_type, engine_path)
                except Exception as e:
                    logger.error("Failed to load %s: %s", leaf_type, e)
            else:
                logger.warning("Engine not found: %s", engine_path)

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
        leaf_type = self.model_selector.currentData()
        engine = self.engines.get(leaf_type)
        if engine is None:
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

        self._inference_worker = InferenceWorker(engine, frame, leaf_type)
        self._inference_worker.result_ready.connect(self._on_result)
        self._inference_worker.error.connect(self._on_inference_error)
        self._inference_worker.start()

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
        # Fix 1.4: Use the inference worker's frozen frame copy, NOT
        # self.current_frame which may have advanced during inference
        analyzed_frame = self._inference_worker.frame
        if analyzed_frame is not None:
            self._display_frame(analyzed_frame, self.analyzed_preview)

        # Active Learning: save the actually-analyzed frame
        image_path = self._save_image(leaf_type, analyzed_frame)

        # Save to database
        self.db.save_prediction(leaf_type, result, image_path=image_path)
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
        models_loaded = ", ".join(self.engines.keys()) or "none"
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
                        except ImportError:
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
        self.db.close()
        logger.info("GUI closed")
        event.accept()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main():
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

    logger.info("Starting AgriKD GUI with config: %s", config_path)

    app = QApplication(sys.argv)
    app.setApplicationName("AgriKD")

    window = MainWindow(config)
    window.show()

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
