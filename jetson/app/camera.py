"""Camera capture for AgriKD Jetson edge inference."""

import signal
import cv2


class _CaptureTimeout(Exception):
    """Raised when camera capture exceeds the configured timeout."""


class CameraCapture:
    """Manages USB/CSI camera via OpenCV."""

    def __init__(self, config):
        self.source = config.get("source", 0)
        self.width = config.get("width", 640)
        self.height = config.get("height", 480)
        # Maximum seconds to wait for a single frame before giving up.
        self.capture_timeout = config.get("capture_timeout_seconds", 10)
        self.cap = None

    def _open(self):
        """Open camera device."""
        if self.cap is None or not self.cap.isOpened():
            self.cap = cv2.VideoCapture(self.source)
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

    def _timeout_handler(self, signum, frame):
        raise _CaptureTimeout("Camera capture timed out")

    def capture_single(self, warmup_frames=3):
        """Wake-Capture-Sleep: open camera, capture one frame, release.

        Fix 1.7 + timeout guard: opens camera, discards warmup frames
        (auto-exposure settle), captures one frame within
        ``self.capture_timeout`` seconds, then releases immediately.
        Raises nothing on timeout — returns None and releases camera.

        Args:
            warmup_frames: Number of frames to discard for auto-exposure.

        Returns:
            BGR numpy array or None if capture failed or timed out.
        """
        self._open()
        if self.cap is None or not self.cap.isOpened():
            return None

        # Use SIGALRM (Unix only) to enforce a hard timeout on blocking reads.
        use_alarm = hasattr(signal, "SIGALRM")
        if use_alarm:
            signal.signal(signal.SIGALRM, self._timeout_handler)
            signal.alarm(self.capture_timeout)
        try:
            # Discard warmup frames for auto-exposure/white-balance settle
            for _ in range(warmup_frames):
                self.cap.read()

            ret, frame = self.cap.read()
            return frame if ret else None
        except _CaptureTimeout:
            return None
        finally:
            if use_alarm:
                signal.alarm(0)  # Cancel pending alarm
            self.release()

    def release(self):
        """Release camera device."""
        if self.cap is not None:
            self.cap.release()
            self.cap = None
