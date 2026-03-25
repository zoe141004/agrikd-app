"""Camera capture for AgriKD Jetson edge inference."""

import cv2


class CameraCapture:
    """Manages USB/CSI camera via OpenCV."""

    def __init__(self, config):
        self.source = config.get("source", 0)
        self.width = config.get("width", 640)
        self.height = config.get("height", 480)
        self.cap = None

    def _open(self):
        """Open camera device."""
        if self.cap is None or not self.cap.isOpened():
            self.cap = cv2.VideoCapture(self.source)
            self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
            self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)

    def capture(self):
        """Capture a single frame.

        Returns:
            BGR numpy array or None if capture failed.
        """
        self._open()
        ret, frame = self.cap.read()
        return frame if ret else None

    def release(self):
        """Release camera device."""
        if self.cap is not None:
            self.cap.release()
            self.cap = None
