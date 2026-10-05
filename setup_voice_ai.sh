#!/usr/bin/env bash

set -e

BASE="/kaggle/working/qwen-voice-ai-kaggle"
VENV="$BASE/vllm-env"
VLLM_PY="$VENV/bin/python"

echo "=========================================="
echo " Qwen Voice AI - Kaggle Setup"
echo "=========================================="

echo
echo "[1/4] Installing uv..."
pip install -q uv

echo
echo "[2/4] Creating Python 3.12.14 environment..."

if [ ! -x "$VLLM_PY" ]; then
    uv venv "$VENV" --python 3.12.14 --seed --managed-python
else
    echo "vllm-env already exists. Skipping environment creation."
fi

echo
echo "[3/4] Installing vLLM..."

uv pip install \
    --python "$VLLM_PY" \
    vllm \
    --torch-backend=auto

echo
echo "[4/4] Verifying installation..."

"$VLLM_PY" --version

"$VLLM_PY" -c "
import torch
import vllm

print('PyTorch:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
print('GPU count:', torch.cuda.device_count())
print('vLLM:', vllm.__version__)

for i in range(torch.cuda.device_count()):
    print(f'GPU {i}:', torch.cuda.get_device_name(i))
"

echo
echo "=========================================="
echo " Setup completed successfully."
echo "=========================================="
