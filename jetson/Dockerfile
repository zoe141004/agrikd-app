# AgriKD Jetson Edge Inference (Headless REST API)
# Base: NVIDIA L4T TensorRT (official JetPack image with CUDA + TensorRT)
#
# Build:  docker build -t agrikd-edge:latest .
# Run:    docker run --rm --runtime=nvidia --network=host \
#           -v /opt/agrikd/config:/app/config:ro \
#           -v /opt/agrikd/models:/app/models:ro \
#           -v /opt/agrikd/data:/app/data \
#           -v /opt/agrikd/logs:/app/logs \
#           agrikd-edge:latest
#
# NOTE: This image is headless only (no GUI/PyQt5).
#       GUI mode runs on the host with system Python.

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

# Install Python dependencies (pinned versions from requirements.txt)
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

# Create non-root user
RUN useradd -m -s /bin/bash agrikd && \
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
