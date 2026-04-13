"""TensorRT inference engine for AgriKD on Jetson."""

import hashlib
import logging
import os
import queue
import threading
import time
from concurrent.futures import Future

import cv2
import numpy as np

logger = logging.getLogger("inference")


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

        # Detect TRT version to choose correct execution API
        self._trt_version = int(trt.__version__.split(".")[0])

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

        # TRT 10+: use execute_async_v3 with named tensors
        if self._trt_version >= 10:
            self._input_name = None
            self._output_name = None
            for i in range(self.engine.num_io_tensors):
                name = self.engine.get_tensor_name(i)
                if self.engine.get_tensor_mode(name) == trt.TensorIOMode.INPUT:
                    self._input_name = name
                else:
                    self._output_name = name
            self.context.set_tensor_address(self._input_name, int(self.d_input))
            self.context.set_tensor_address(self._output_name, int(self.d_output))

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

        if self._trt_version >= 10:
            # TRT 10+: addresses already set in _load_engine
            self.context.execute_async_v3(stream_handle=self.stream.handle)
        else:
            # TRT 8.x legacy path
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

    def cleanup(self):
        """Release CUDA device memory and TensorRT resources."""
        import importlib.util
        if importlib.util.find_spec('pycuda') is None:
            return

        for attr in ("d_input", "d_output"):
            buf = getattr(self, attr, None)
            if buf is not None:
                try:
                    buf.free()
                except Exception:  # noqa: BLE001 — best-effort CUDA cleanup
                    logger.debug("Failed to free CUDA buffer %s", attr)
                setattr(self, attr, None)

        for attr in ("stream", "context", "engine"):
            obj = getattr(self, attr, None)
            if obj is not None:
                del obj
                setattr(self, attr, None)

        self.h_input = None
        self.h_output = None
        logger.debug("TensorRT resources released for %s", self.engine_path)

    def __del__(self):
        self.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()
        return False


# ── Sentinel to signal worker shutdown ──
_SHUTDOWN = object()
_HOT_SWAP = object()  # Sentinel for hot-swap jobs


class InferenceWorkerPool:
    """Thread-safe inference pool.

    A single worker thread owns the CUDA context and all TensorRT engine
    buffers.  Callers from *any* thread use ``submit(leaf_type, frame)``
    which returns a ``concurrent.futures.Future``.  The worker picks jobs
    off an internal queue, runs ``engine.predict(frame)``, and resolves
    the future.

    This eliminates all CUDA context-affinity and shared-buffer race
    conditions (C1 in the audit) without requiring ``cuda.Context.push/pop``.
    """

    def __init__(self, config, inference_config=None):
        """Build engines from *config* (the ``models`` section).

        Engine construction happens on the **worker thread** so that
        ``pycuda.autoinit`` binds the CUDA context there.
        """
        self._model_configs = config
        self._inference_config = inference_config or {}
        self._engines = {}          # Populated by worker thread
        self._queue = queue.Queue()
        self._ready = threading.Event()
        self._error: BaseException | None = None  # Propagate init errors to main thread
        self._leaf_types = []       # Available engines after init

        self._thread = threading.Thread(
            target=self._worker_loop, daemon=True, name="inference-worker",
        )
        self._thread.start()

        # Block until engines are loaded (or worker reports an error)
        self._ready.wait()
        if self._error is not None:
            raise RuntimeError(f"Engine init failed: {self._error}") from self._error

    # ── Public API ──────────────────────────────────────────────────

    def submit(self, leaf_type, frame):
        """Submit an inference job.  Returns a Future.

        Usage::

            future = pool.submit("tomato", frame)
            result = future.result(timeout=30)
        """
        fut = Future()
        self._queue.put((leaf_type, frame, fut))
        return fut

    def available_engines(self):
        """Return list of loaded leaf-type names."""
        return list(self._leaf_types)

    def shutdown(self):
        """Signal the worker to exit and clean up GPU resources."""
        self._queue.put(_SHUTDOWN)
        self._thread.join(timeout=10)
        for engine in self._engines.values():
            engine.cleanup()
        self._engines.clear()

    def hot_swap(self, leaf_type, engine_path, model_meta=None):
        """Hot-swap a single engine on the CUDA worker thread.

        Thread-safe: queues a swap job and waits for completion.
        The old engine is cleaned up and replaced atomically.

        Args:
            leaf_type: e.g. "tomato"
            engine_path: path to new .engine file
            model_meta: dict with num_classes, class_labels (optional)
        """
        fut = Future()
        self._queue.put((_HOT_SWAP, leaf_type, engine_path, model_meta, fut))
        # Wait for swap to complete (up to 120s for engine deserialization on slower Jetson devices)
        result = fut.result(timeout=120)
        return result

    # ── Worker (runs on its own thread — owns CUDA context) ─────────

    def _worker_loop(self):
        """Dequeue jobs and run predict() sequentially."""
        try:
            self._init_engines()
        except Exception as exc:
            self._error = exc
            self._ready.set()
            return

        self._ready.set()
        logger.info(
            "Inference worker ready — engines: %s",
            ", ".join(self._leaf_types),
        )

        consecutive_errors = 0
        while True:
            try:
                job = self._queue.get()
                if job is _SHUTDOWN:
                    logger.info("Inference worker shutting down")
                    break

                # Handle hot-swap request (runs on CUDA thread)
                if isinstance(job, tuple) and len(job) == 5 and job[0] is _HOT_SWAP:
                    _, lt, path, meta, swap_fut = job
                    try:
                        self._do_hot_swap(lt, path, meta)
                        swap_fut.set_result(True)
                    except Exception as exc:
                        swap_fut.set_exception(exc)
                    continue

                leaf_type, frame, fut = job
                try:
                    engine = self._engines.get(leaf_type)
                    if engine is None:
                        fut.set_exception(
                            ValueError(f"Unknown leaf type: {leaf_type}")
                        )
                    else:
                        result = engine.predict(frame)
                        fut.set_result(result)
                        consecutive_errors = 0
                except Exception as exc:
                    fut.set_exception(exc)
                    consecutive_errors += 1
                    logger.error(
                        "Inference error (%d consecutive): %s",
                        consecutive_errors, exc,
                    )
                    # Attempt CUDA memory cleanup to prevent leaks
                    try:
                        import torch
                        if torch.cuda.is_available():
                            torch.cuda.empty_cache()
                    except ImportError:  # torch not installed on this device
                        pass
                    if consecutive_errors >= 10:
                        logger.critical(
                            "10 consecutive inference failures — worker staying alive "
                            "but CUDA state may be corrupt"
                        )
            except Exception as outer_exc:
                logger.critical(
                    "Unexpected error in inference worker loop: %s", outer_exc
                )

    def _init_engines(self):
        """Load TensorRT engines ON the worker thread (CUDA-owner)."""
        for leaf_type, model_cfg in self._model_configs.items():
            engine_path = model_cfg["engine_path"]
            if not os.path.exists(engine_path):
                logger.warning(
                    "Engine not found: %s — skipping %s", engine_path, leaf_type,
                )
                continue
            eng = TensorRTInference(
                engine_path,
                model_cfg,
                expected_sha256=model_cfg.get("sha256_checksum"),
                inference_config=self._inference_config,
            )
            self._engines[leaf_type] = eng
            logger.info("Loaded TensorRT engine: %s (%s)", leaf_type, engine_path)

        if not self._engines:
            raise RuntimeError("No TensorRT engines loaded.")

        self._leaf_types = list(self._engines.keys())

    def _do_hot_swap(self, leaf_type, engine_path, model_meta=None):
        """Replace a single engine (runs on CUDA worker thread).

        Loads the new engine FIRST, then cleans up the old one — so if the
        new engine fails to load, the old engine remains functional.
        """
        # Build model_cfg for the new engine
        model_cfg = dict(self._model_configs.get(leaf_type, {}))
        model_cfg["engine_path"] = engine_path
        if model_meta:
            if "num_classes" in model_meta:
                model_cfg["num_classes"] = model_meta["num_classes"]
            if "class_labels" in model_meta:
                model_cfg["class_labels"] = model_meta["class_labels"]

        # Load new engine BEFORE cleaning up old (safe degradation)
        new_engine = TensorRTInference(
            engine_path,
            model_cfg,
            inference_config=self._inference_config,
        )

        # New engine loaded OK — now clean up old
        old_engine = self._engines.get(leaf_type)
        if old_engine:
            logger.info("Cleaning up old engine: %s", leaf_type)
            old_engine.cleanup()

        self._engines[leaf_type] = new_engine
        self._model_configs[leaf_type] = model_cfg

        if leaf_type not in self._leaf_types:
            self._leaf_types.append(leaf_type)

        logger.info("Hot-swapped engine: %s → %s", leaf_type, engine_path)
