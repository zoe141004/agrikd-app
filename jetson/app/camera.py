"""Camera capture for AgriKD Jetson edge inference."""

import logging
import time

import cv2
import numpy as np

logger = logging.getLogger("camera")

# Maximum time (seconds) to wait for camera to open
_OPEN_TIMEOUT = 10
# Exponential backoff limits for reconnection
_MAX_BACKOFF = 60
_INITIAL_BACKOFF = 1


class CameraCapture:
    """Manages USB/CSI camera via OpenCV."""

    def __init__(self, config):
        self.source = config.get("source", 0)
        self.width = config.get("width", 640)
        self.height = config.get("height", 480)
        self.cap = None
        self._backoff = _INITIAL_BACKOFF

    def _open(self):
        """Open camera device with timeout guard."""
        if self.cap is None or not self.cap.isOpened():
            self.cap = cv2.VideoCapture(self.source)
            deadline = time.monotonic() + _OPEN_TIMEOUT
            while not self.cap.isOpened():
                if time.monotonic() > deadline:
                    self.release()
                    raise TimeoutError(
                        f"Camera source {self.source} did not open within "
                        f"{_OPEN_TIMEOUT}s"
                    )
                time.sleep(0.1)
            self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
            self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
            self._backoff = _INITIAL_BACKOFF  # Reset on success

    def _open_with_reconnect(self):
        """Open camera with exponential backoff reconnection."""
        while True:
            try:
                self._open()
                return
            except TimeoutError:
                logger.warning(
                    "Camera reconnect failed, retrying in %ds", self._backoff,
                )
                time.sleep(self._backoff)
                self._backoff = min(self._backoff * 2, _MAX_BACKOFF)

    @staticmethod
    def _validate_frame(frame):
        """Check that a captured frame is usable (not blank/corrupt)."""
        if frame is None or frame.size == 0:
            return False
        # Histogram entropy check — reject near-uniform frames (lens cap, dead sensor)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        hist = cv2.calcHist([gray], [0], None, [256], [0, 256]).flatten()
        hist = hist / hist.sum()
        nonzero = hist[hist > 0]
        entropy = -np.sum(nonzero * np.log2(nonzero))
        if entropy < 1.0:
            logger.warning("Frame rejected: low entropy (%.2f)", entropy)
            return False
        return True

    def capture(self):
        """Capture a single frame (camera stays open).

        Returns:
            BGR numpy array or None if capture failed.
        """
        self._open()
        ret, frame = self.cap.read()
        return frame if ret else None

    def capture_single(self, warmup_frames=3):
        """Wake-Capture-Sleep: open camera, capture one frame, release.

        Fix 1.7: For periodic mode — opens camera, discards warmup frames
        (auto-exposure settle), captures one frame, then releases immediately.
        Reduces Jetson heat and sensor wear during long intervals.

        Uses exponential backoff reconnection if camera open fails.

        Args:
            warmup_frames: Number of frames to discard for auto-exposure.

        Returns:
            BGR numpy array or None if capture failed validation.
        """
        try:
            self._open_with_reconnect()
            if self.cap is None or not self.cap.isOpened():
                return None

            # Discard warmup frames for auto-exposure/white-balance settle
            for _ in range(warmup_frames):
                self.cap.read()

            ret, frame = self.cap.read()
            if not ret or not self._validate_frame(frame):
                return None
            return frame
        except TimeoutError:
            logger.error("Camera open timeout in capture_single")
            return None
        finally:
            self.release()

    def release(self):
        """Release camera device."""
        if self.cap is not None:
            self.cap.release()
            self.cap = None
