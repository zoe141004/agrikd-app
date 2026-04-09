"""Camera capture for AgriKD Jetson edge inference."""

import logging
import time

import cv2

logger = logging.getLogger("camera")

# Maximum time (seconds) to wait for camera to open
_OPEN_TIMEOUT = 10


class CameraCapture:
    """Manages USB/CSI camera via OpenCV."""

    def __init__(self, config):
        self.source = config.get("source", 0)
        self.width = config.get("width", 640)
        self.height = config.get("height", 480)
        self.cap = None

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

        Args:
            warmup_frames: Number of frames to discard for auto-exposure.

        Returns:
            BGR numpy array or None if capture failed.
        """
        try:
            self._open()
            if self.cap is None or not self.cap.isOpened():
                return None

            # Discard warmup frames for auto-exposure/white-balance settle
            for _ in range(warmup_frames):
                self.cap.read()

            ret, frame = self.cap.read()
            return frame if ret else None
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
