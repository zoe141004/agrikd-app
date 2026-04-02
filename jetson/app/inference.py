"""TensorRT inference engine for AgriKD on Jetson."""

import hashlib
import time

import cv2
import numpy as np


class TensorRTInference:
    """Runs TensorRT FP16 inference on a loaded engine."""

    def __init__(self, engine_path, model_config, expected_sha256=None, inference_config=None):
        self.engine_path = engine_path
        self.expected_sha256 = expected_sha256
        self.num_classes = model_config["num_classes"]
        self.class_labels = model_config["class_labels"]

        # H7: Read input_size/mean/std from config with fallback defaults
        inf_cfg = inference_config or {}
        self.input_size = inf_cfg.get("input_size", 224)
        self.mean = np.array(
            inf_cfg.get("imagenet_mean", [0.485, 0.456, 0.406]), dtype=np.float32
        )
        self.std = np.array(
            inf_cfg.get("imagenet_std", [0.229, 0.224, 0.225]), dtype=np.float32
        )

        self._load_engine()

    def _load_engine(self):
        """Load TensorRT engine and allocate buffers."""
        try:
            import tensorrt as trt
            import pycuda.driver as cuda
            import pycuda.autoinit  # noqa: F401
        except ImportError:
            raise RuntimeError(
                "TensorRT or PyCUDA not installed. "
                "Install JetPack SDK on your Jetson device."
            )

        self.logger = trt.Logger(trt.Logger.WARNING)

        # Verify engine file integrity before loading
        if self.expected_sha256:
            sha256 = hashlib.sha256()
            with open(self.engine_path, "rb") as f:
                for chunk in iter(lambda: f.read(8192), b""):
                    sha256.update(chunk)
            actual = sha256.hexdigest()
            if actual != self.expected_sha256:
                raise ValueError(
                    f"Engine checksum mismatch for {self.engine_path}: "
                    f"expected {self.expected_sha256}, got {actual}"
                )

        with open(self.engine_path, "rb") as f:
            runtime = trt.Runtime(self.logger)
            self.engine = runtime.deserialize_cuda_engine(f.read())

        # H4: Guard against deserialization failure
        if self.engine is None:
            raise RuntimeError(
                f"Failed to deserialize TensorRT engine: {self.engine_path}. "
                "Ensure the engine was built for this GPU architecture."
            )

        self.context = self.engine.create_execution_context()

        # Allocate host and device buffers
        self.h_input = cuda.pagelocked_empty(
            (1, 3, self.input_size, self.input_size), dtype=np.float32
        )
        self.h_output = cuda.pagelocked_empty(
            (1, self.num_classes), dtype=np.float32
        )
        self.d_input = cuda.mem_alloc(self.h_input.nbytes)
        self.d_output = cuda.mem_alloc(self.h_output.nbytes)
        self.stream = cuda.Stream()

    def preprocess(self, frame):
        """Preprocess BGR frame to NCHW float32 tensor."""
        img = cv2.resize(frame, (self.input_size, self.input_size))
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        img = img.astype(np.float32) / 255.0
        img = (img - self.mean) / self.std
        # HWC -> CHW
        img = np.transpose(img, (2, 0, 1))
        return np.expand_dims(img, axis=0).astype(np.float32)

    def predict(self, frame):
        """Run inference on a single frame.

        Args:
            frame: BGR numpy array from OpenCV.

        Returns:
            dict with class_index, class_name, confidence,
            all_confidences, inference_time_ms.
        """
        import pycuda.driver as cuda

        tensor = self.preprocess(frame)
        np.copyto(self.h_input, tensor)

        start = time.perf_counter()

        cuda.memcpy_htod_async(self.d_input, self.h_input, self.stream)
        self.context.execute_async_v2(
            bindings=[int(self.d_input), int(self.d_output)],
            stream_handle=self.stream.handle,
        )
        cuda.memcpy_dtoh_async(self.h_output, self.d_output, self.stream)
        self.stream.synchronize()

        elapsed_ms = (time.perf_counter() - start) * 1000

        logits = self.h_output[0]
        # Softmax
        exp_logits = np.exp(logits - np.max(logits))
        probs = exp_logits / exp_logits.sum()

        class_idx = int(np.argmax(probs))

        return {
            "class_index": class_idx,
            "class_name": self.class_labels[class_idx],
            "confidence": float(probs[class_idx]),
            "all_confidences": probs.tolist(),
            "inference_time_ms": round(elapsed_ms, 2),
        }
