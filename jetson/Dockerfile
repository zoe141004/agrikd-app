# AgriKD Jetson Edge Inference
# Base: NVIDIA L4T TensorRT (official JetPack image)
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

# Install Python dependencies
RUN pip3 install --no-cache-dir \
    numpy>=1.24 \
    opencv-python-headless>=4.8 \
    requests>=2.31 \
    flask>=3.0 \
    waitress>=3.0

# Create non-root user
RUN useradd -m -s /bin/bash agrikd && \
    mkdir -p /app/models /app/data /app/logs && \
    chown -R agrikd:agrikd /app

WORKDIR /app
COPY --chown=agrikd:agrikd app/ /app/
COPY --chown=agrikd:agrikd config/ /app/config/

USER agrikd

# Health check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080

CMD ["python3", "main.py"]
