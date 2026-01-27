# ComfyUI Docker Image with Blackwell NVFP4 Support
# Optimized for NVIDIA Blackwell GPUs (RTX 50 series)

# Build arguments for version pinning --Global Scope--
ARG CUDA_BASE_IMAGE=nvidia/cuda:13.1.0-devel-ubuntu24.04
ARG TORCH_WHEEL_URL=https://download.pytorch.org/whl/cu130/torch-2.10.0%2Bcu130-cp312-cp312-manylinux_2_28_x86_64.whl
ARG TORCHVISION_WHEEL_URL=https://download.pytorch.org/whl/cu130/torchvision-0.25.0%2Bcu130-cp312-cp312-manylinux_2_28_x86_64.whl
ARG TORCHAUDIO_WHEEL_URL=https://download.pytorch.org/whl/cu130/torchaudio-2.10.0%2Bcu130-cp312-cp312-manylinux_2_28_x86_64.whl
ARG COMFYUI_BRANCH=master
ARG SAGEATTENTION_VERSION=v2
ARG SAGEATTENTION_USE=1

FROM ${CUDA_BASE_IMAGE}
# Re-declaring these ARGs so they are available inside this build stage
ARG SAGEATTENTION_VERSION
ARG TORCH_WHEEL_URL
ARG TORCHVISION_WHEEL_URL
ARG TORCHAUDIO_WHEEL_URL
ARG COMFYUI_BRANCH
# Pass these to the runtime so the CMD can see it later
ENV SAGEATTENTION_VERSION=${SAGEATTENTION_VERSION}
ENV SAGEATTENTION_USE=${SAGEATTENTION_USE}
# Setup environment for non-interactive installs
ENV DEBIAN_FRONTEND=noninteractive
# Allow pip to install in system Python (we're in a container, it's fine)
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_IGNORE_INSTALLED=1
ENV PIP_NO_CACHE_DIR=1

# Install system dependencies
# libgl1, libglib2.0-0: Required for OpenCV (used by many custom nodes)
# ffmpeg: Video processing support
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    git \
    libgl1 \
    libglib2.0-0 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip to latest version
RUN python3 -m pip install --upgrade pip

# Set working directory
WORKDIR /app

# Clone ComfyUI repository
ARG COMFYUI_BRANCH
RUN git clone --branch ${COMFYUI_BRANCH} https://github.com/comfyanonymous/ComfyUI.git .

# Install PyTorch with CUDA 13.0 support
# These specific wheels are critical for Blackwell GPU support
ARG TORCH_WHEEL_URL
ARG TORCHVISION_WHEEL_URL
ARG TORCHAUDIO_WHEEL_URL

RUN pip install \
    "${TORCH_WHEEL_URL}" \
    "${TORCHVISION_WHEEL_URL}" \
    "${TORCHAUDIO_WHEEL_URL}"

# Create a constraints file to protect PyTorch versions
# This prevents custom nodes from accidentally downgrading/upgrading PyTorch
RUN echo "torch @ ${TORCH_WHEEL_URL}" > /app/constraints.txt && \
    echo "torchvision @ ${TORCHVISION_WHEEL_URL}" >> /app/constraints.txt && \
    echo "torchaudio @ ${TORCHAUDIO_WHEEL_URL}" >> /app/constraints.txt

# Install SageAttention for improved attention mechanism performance
# Triton is required for SageAttention's CUDA kernels
RUN if [ "$SAGEATTENTION_VERSION" != "none" ]; then \
      pip install triton -c /app/constraints.txt && \
      git clone https://github.com/thu-ml/SageAttention.git /app/tmp/sageattention && \
      if [ "$SAGEATTENTION_VERSION" = "v3" ]; then \
        cd /app/tmp/sageattention/sageattention3_blackwell; \
      elif [ "$SAGEATTENTION_VERSION" = "v2" ]; then \
        cd /app/tmp/sageattention; \
      else \
        echo "ERROR: SAGEATTENTION_VERSION must be v2, v3 or none" && exit 1; \
      fi && \
      pip install -c /app/constraints.txt . && \
      cd /app && \
      rm -rf /app/tmp/sageattention; \
    fi

# Install base ComfyUI requirements
RUN pip install -r requirements.txt -c /app/constraints.txt

# Install additional wheels from wheels.txt if provided
# This is where Nunchaku and other special packages go
# The wheels.txt file should be in the build context
RUN --mount=type=bind,source=.,target=/mnt/context,ro \
    if [ -f "/mnt/context/wheels.txt" ]; then \
        echo "Found wheels.txt, installing wheels..."; \
        while IFS= read -r wheel_url || [ -n "$wheel_url" ]; do \
            # Skip comments and empty lines
            case "$wheel_url" in \
                \#*|"") continue ;; \
            esac; \
            echo "Installing: $wheel_url"; \
            pip install "$wheel_url" -c /app/constraints.txt || true; \
        done < /mnt/context/wheels.txt; \
    else \
        echo "No wheels.txt found, skipping additional wheels..."; \
    fi

# Install dependencies from custom nodes that are already present
# This bakes in requirements for nodes you've already installed
# NOTE: If you add nodes via ComfyUI Manager, you must rebuild!
RUN --mount=type=bind,source=.,target=/mnt/context,ro \
    if [ -d "/mnt/context/custom_nodes" ]; then \
        echo "Installing custom node dependencies..."; \
        find /mnt/context/custom_nodes -maxdepth 2 -name "requirements.txt" \
        -exec pip install -r {} -c /app/constraints.txt \; || true; \
    fi

# Create startup script that runs install.py for custom nodes
# Some custom nodes need post-install setup that happens at runtime
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
# Protect PyTorch versions from being changed\n\
export PIP_CONSTRAINT=/app/constraints.txt\n\
\n\
# Run install.py scripts for any custom nodes that have them\n\
if [ -d "/app/custom_nodes" ]; then\n\
    for dir in /app/custom_nodes/*/; do\n\
        if [ -f "$dir/install.py" ]; then\n\
            echo "Running install script for $(basename $dir)..."\n\
            cd "$dir" && python3 install.py || true\n\
            cd /app\n\
        fi\n\
    done\n\
fi\n\
\n\
echo "Starting ComfyUI..."\n\
exec "$@"\n\
' > /app/startup.sh && chmod +x /app/startup.sh

# Expose ComfyUI web interface port
EXPOSE 8188

# Use startup script as entrypoint
ENTRYPOINT ["/app/startup.sh"]

# Default command - can be overridden in docker-compose.yml
CMD if [ "$SAGEATTENTION_USE" != "0" ] && { [ "$SAGEATTENTION_VERSION" = "v2" ] || [ "$SAGEATTENTION_VERSION" = "v3" ]; }; then \
      exec python3 main.py --listen 0.0.0.0 --use-sage-attention; \
    else \
      exec python3 main.py --listen 0.0.0.0; \
    fi
