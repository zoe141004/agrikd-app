"""Shared TensorRT engine build utilities.

Centralises trtexec discovery and engine-build logic so that both
setup_jetson.sh (via Python helpers) and sync_engine.py use identical
parameters — avoiding divergence bugs like --workspace failures.
"""

import logging
import os
import shutil
import subprocess

logger = logging.getLogger("engine_builder")

# Known JetPack / system locations for trtexec
_TRTEXEC_CANDIDATES = [
    "/usr/src/tensorrt/bin/trtexec",
    "/usr/local/cuda/bin/trtexec",
    "/usr/lib/tensorrt/bin/trtexec",
    "/opt/tensorrt/bin/trtexec",
    "/usr/local/bin/trtexec",
]


def find_trtexec() -> str | None:
    """Locate the trtexec binary on this system.

    Search order:
      1. PATH (via shutil.which)
      2. Known JetPack / system install locations
      3. ~/trtexec (user-compiled fallback)

    Returns the absolute path or None if not found.
    """
    path = shutil.which("trtexec")
    if path:
        return path

    for candidate in _TRTEXEC_CANDIDATES:
        if os.path.isfile(candidate):
            return candidate

    home_trtexec = os.path.expanduser("~/trtexec")
    if os.path.isfile(home_trtexec):
        return home_trtexec

    return None


def build_engine(onnx_path: str, engine_path: str, *,
                 timeout: int = 1800, workspace_mb: int = 1024) -> None:
    """Convert an ONNX model to a TensorRT engine using trtexec.

    Uses --fp16 with sufficient workspace for optimal layer fusion and
    kernel selection.  Matches the flags in convert_onnx_to_tensorrt.py
    to ensure consistent accuracy across CI and on-device builds.

    Args:
        onnx_path:    Path to the source .onnx file.
        engine_path:  Destination path for the .engine file.
        timeout:      Max seconds to wait for trtexec (default 30 min).
        workspace_mb: Max workspace size in MB for TRT builder (default 1024).

    Raises:
        FileNotFoundError: trtexec binary not found.
        RuntimeError:      trtexec exited with non-zero status.
    """
    trtexec_bin = find_trtexec()
    if not trtexec_bin:
        raise FileNotFoundError(
            "trtexec not found in PATH or known locations: "
            + ", ".join(_TRTEXEC_CANDIDATES)
        )

    logger.info("Using trtexec: %s", trtexec_bin)
    result = subprocess.run(
        [trtexec_bin,
         f"--onnx={onnx_path}",
         f"--saveEngine={engine_path}",
         "--fp16",
         f"--memPoolSize=workspace:{workspace_mb}MiB"],
        capture_output=True, text=True, timeout=timeout,
    )
    if result.returncode != 0:
        # Include last 500 chars of stderr for diagnostics
        detail = (result.stderr or "")[-500:]
        raise RuntimeError(f"trtexec failed (exit {result.returncode}): {detail}")
