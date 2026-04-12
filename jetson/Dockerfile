# ================================================================
# AgriKD Jetson Edge Inference — Dockerfile (DEPRECATED)
# ================================================================
# This Dockerfile is DEPRECATED and NOT used by setup_jetson.sh.
#
# Reason: NVIDIA does not provide an official JetPack 6 Docker
# base image with TRT 10.x + Python 3.10. The base image below
# uses JetPack 5 (TRT 8.5, Python 3.8, CUDA 11.4) which is
# incompatible with JetPack 6 hardware (TRT 10.x, Python 3.10,
# CUDA 12.x). TensorRT engines are NOT portable across versions.
#
# Current deployment: host-native via systemd (see agrikd.service).
# This file is kept for reference only.
# ================================================================

FROM nvcr.io/nvidia/l4t-tensorrt:r8.5.2-runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-dev \
    libopencv-dev \
    libsqlite3-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Ensure CUDA/TensorRT library paths are visible at runtime
ENV PATH="/usr/local/cuda/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH}"

# Install Python dependencies (pinned versions from requirements.txt)
# NOTE: TensorRT and PyCUDA are NOT installed here — they are provided at
# runtime via --runtime=nvidia and host bind-mounts configured in setup_jetson.sh.
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

# Create non-root user — UID/GID passed from setup script to match host
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupadd -g $HOST_GID agrikd 2>/dev/null || true && \
    useradd -m -u $HOST_UID -g $HOST_GID -s /bin/bash agrikd && \
    mkdir -p /app/models /app/data /app/logs && \
    chown -R agrikd:agrikd /app

WORKDIR /app
COPY --chown=agrikd:agrikd app/ /app/

USER agrikd

# Health check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

CMD ["python3", "main.py"]
