# syntax=docker/dockerfile:1.4
# Stage 1: Base image with common dependencies
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04 AS base

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python 3.12, git, build tools and other necessary tools
# Build tools are needed for ReActor's InsightFace compilation
RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    python3-pip \
    git \
    wget \
    build-essential \
    cmake \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
# Use cache mount for faster subsequent builds
RUN --mount=type=cache,target=/root/.cache/pip \
    uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI
# Use cache mount to speed up pip operations
RUN --mount=type=cache,target=/root/.cache/pip \
    /usr/bin/yes | comfy --workspace /comfyui install --cuda-version 12.1 --nvidia

# Change working directory to ComfyUI
WORKDIR /comfyui

# Copy scripts first (they change less frequently than code)
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Clone all custom node repositories in parallel
# This is much faster than sequential clones
RUN mkdir -p custom_nodes && \
    (git clone --depth 1 https://github.com/WASasquatch/was-node-suite-comfyui.git custom_nodes/was-node-suite-comfyui & \
     git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git custom_nodes/ComfyUI-Impact-Pack & \
     git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git custom_nodes/ComfyUI-Impact-Subpack & \
     git clone --depth 1 https://github.com/Gourieff/ComfyUI-ReActor.git custom_nodes/ComfyUI-ReActor & \
     git clone --depth 1 https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git custom_nodes/ComfyUI_Comfyroll_CustomNodes & \
     git clone --depth 1 https://github.com/RndNanthu/ComfyUI-RndNanthu.git custom_nodes/ComfyUI-RndNanthu & \
     git clone --depth 1 https://github.com/EllangoK/ComfyUI-post-processing-nodes.git custom_nodes/ComfyUI-post-processing-nodes & \
     git clone --depth 1 https://github.com/yolain/ComfyUI-Easy-Use.git custom_nodes/ComfyUI-Easy-Use & \
     git clone --depth 1 https://github.com/Visionatrix/ComfyUI-Gemini.git custom_nodes/ComfyUI-Gemini & \
     git clone --depth 1 https://github.com/mav-rik/facerestore_cf.git custom_nodes/facerestore_cf & \
     git clone --depth 1 https://github.com/Comfy-Org/comfy-aimdo.git custom_nodes/comfy-aimdo & \
     wait)

# Try to install KJ Nodes via comfy-node-install, fallback to git clone
RUN (comfy-node-install comfyui-kjnodes || \
     git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git custom_nodes/ComfyUI-KJNodes) || \
    (echo "Warning: KJ Nodes installation failed" && true)

# Install GeminiImageDirectNode - Direct Gemini API integration for speed
COPY custom_nodes/GeminiImageDirectNode /comfyui/custom_nodes/GeminiImageDirectNode

# Install VertexAIImageNode - Vertex AI Imagen API integration
COPY custom_nodes/VertexAIImageNode /comfyui/custom_nodes/VertexAIImageNode

# Collect all requirements.txt files and install dependencies in one go
# This is much faster than installing them separately
RUN --mount=type=cache,target=/root/.cache/pip \
    find custom_nodes -name "requirements.txt" -type f | \
    xargs -I {} sh -c 'echo "=== Installing from {} ===" && pip install --no-cache-dir -r {} || true' && \
    pip install --no-cache-dir ultralytics onnxruntime-gpu insightface facexlib olefile

# Install ReActor Face Swap dependencies (install.py compiles InsightFace from source)
RUN --mount=type=cache,target=/root/.cache/pip \
    (cd custom_nodes/ComfyUI-ReActor && python install.py) || \
    (echo "Warning: ReActor install.py failed, trying fallback installation" && \
     pip install --no-cache-dir -r custom_nodes/ComfyUI-ReActor/requirements.txt || true)

# Disable ReActor NSFW check (no filtering, no model download at runtime, to avoid rate limiting)
RUN python -c "import pathlib; p = pathlib.Path('custom_nodes/ComfyUI-ReActor/scripts/reactor_sfw.py'); s = p.read_text(); old = 'def nsfw_image(img_data, model_path: str):'; new = 'def nsfw_image(img_data, model_path: str):\n    return False  # NSFW check disabled'; s = (s.replace(old, new, 1) if old in s and new not in s else s); p.write_text(s); print('ReActor NSFW check disabled')"

# Set proper permissions for all custom nodes
RUN chmod -R 755 custom_nodes/

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler (GCP + S3 compatibility)
RUN --mount=type=cache,target=/root/.cache/pip \
    uv pip install requests websocket-client boto3 sqlalchemy alembic \
    google-cloud-storage google-cloud-tasks google-cloud-firestore google-cloud-pubsub \
    comfy-aimdo

# Add application code and scripts
ADD src/start.sh src/gcp_entrypoint.sh handler.py gcp_storage.py gcp_server.py ./
RUN chmod +x /start.sh /gcp_entrypoint.sh

# Copy helper scripts
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

COPY scripts/comfy-set-api-key.sh /usr/local/bin/comfy-set-api-key
RUN chmod +x /usr/local/bin/comfy-set-api-key

COPY scripts/comfy-auto-login.sh /usr/local/bin/comfy-auto-login
RUN chmod +x /usr/local/bin/comfy-auto-login

COPY scripts/fix-comfy-api-nodes-auth.py /scripts/fix-comfy-api-nodes-auth.py
RUN chmod +x /scripts/fix-comfy-api-nodes-auth.py

# Set the default command to run when starting the container
CMD ["/start.sh"]

# Stage 2: Download models
FROM base AS downloader

ARG HUGGINGFACE_ACCESS_TOKEN
# Set default model type if none is provided
ARG MODEL_TYPE=flux1-dev-fp8

# Change working directory to ComfyUI
WORKDIR /comfyui

# Create necessary directories upfront
RUN mkdir -p models/checkpoints models/vae models/unet models/clip models/facerestore_models models/insightface models/ultralytics/bbox models/upscale_models models/facedetection models/nsfw_detector/vit-base-nsfw-detector

# Pre-download ReActor NSFW detector (vit-base-nsfw-detector) so runtime does not hit Hugging Face 429
RUN wget -q -O models/nsfw_detector/vit-base-nsfw-detector/config.json \
    "https://huggingface.co/AdamCodd/vit-base-nsfw-detector/resolve/main/config.json" && \
    wget -q -O models/nsfw_detector/vit-base-nsfw-detector/preprocessor_config.json \
    "https://huggingface.co/AdamCodd/vit-base-nsfw-detector/resolve/main/preprocessor_config.json" && \
    wget -q -O models/nsfw_detector/vit-base-nsfw-detector/model.safetensors \
    "https://huggingface.co/AdamCodd/vit-base-nsfw-detector/resolve/main/model.safetensors" && \
    echo "ReActor NSFW detector pre-downloaded"

# Download models in parallel where possible
RUN wget -q -O models/ultralytics/bbox/face_yolov8m.pt https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/detection/bbox/face_yolov8m.pt & \
    wget -q -O models/upscale_models/1x-ITF-SkinDiffDetail-Lite-v1.pth https://huggingface.co/alexgenovese/upscalers/resolve/main/1x-ITF-SkinDiffDetail-Lite-v1.pth & \
    wait

# Download ReActor face detection model (yolov5l-face.pth) from GitHub with retry logic
RUN for i in 1 2 3 4 5; do \
      wget -q --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
           -O models/facedetection/yolov5l-face.pth \
           https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/yolov5l-face.pth && \
      break || sleep 5; \
    done || echo "Warning: Failed to download yolov5l-face.pth after 5 attempts"

# Download checkpoints/vae/unet/clip models to include in image based on model type
RUN if [ "$MODEL_TYPE" = "sdxl" ]; then \
      wget -q -O models/checkpoints/sd_xl_base_1.0.safetensors https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors & \
      wget -q -O models/vae/sdxl_vae.safetensors https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors & \
      wget -q -O models/vae/sdxl-vae-fp16-fix.safetensors https://huggingface.co/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors & \
      wait; \
    fi

RUN if [ "$MODEL_TYPE" = "sd3" ]; then \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/checkpoints/sd3_medium_incl_clips_t5xxlfp8.safetensors https://huggingface.co/stabilityai/stable-diffusion-3-medium/resolve/main/sd3_medium_incl_clips_t5xxlfp8.safetensors; \
    fi

RUN if [ "$MODEL_TYPE" = "flux1-schnell" ]; then \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/unet/flux1-schnell.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/flux1-schnell.safetensors & \
      wget -q -O models/clip/clip_l.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors & \
      wget -q -O models/clip/t5xxl_fp8_e4m3fn.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors & \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/vae/ae.safetensors https://huggingface.co/black-forest-labs/FLUX.1-schnell/resolve/main/ae.safetensors & \
      wait; \
    fi

RUN if [ "$MODEL_TYPE" = "flux1-dev" ]; then \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/unet/flux1-dev.safetensors https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors & \
      wget -q -O models/clip/clip_l.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors & \
      wget -q -O models/clip/t5xxl_fp8_e4m3fn.safetensors https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors & \
      wget -q --header="Authorization: Bearer ${HUGGINGFACE_ACCESS_TOKEN}" -O models/vae/ae.safetensors https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/ae.safetensors & \
      wait; \
    fi

RUN if [ "$MODEL_TYPE" = "flux1-dev-fp8" ]; then \
      wget -q -O models/checkpoints/flux1-dev-fp8.safetensors https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors; \
    fi

# Stage 3: Final image
FROM base AS final

# Copy models from stage 2 to the final image
COPY --from=downloader /comfyui/models /comfyui/models

# Copy custom model files (codeformer and inswapper) from local new/ directory
# These will be copied during build from the build context
COPY new/codeformer-v0.1.0.pth /comfyui/models/facerestore_models/codeformer-v0.1.0.pth
COPY new/inswapper_128.onnx /comfyui/models/insightface/inswapper_128.onnx
