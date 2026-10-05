#!/usr/bin/env bash
set -e

BASE="/kaggle/working/qwen-voice-ai-kaggle"

echo "=========================================="
echo " Qwen Voice AI - FULL STARTUP"
echo "=========================================="
echo

echo "[1/3] Starting Qwen vLLM + WebSocket bridge..."
"$BASE/start_voice_ai.sh"

echo
echo "[2/3] Starting Cloudflare tunnel..."
"$BASE/start_cloudflare.sh"

echo
echo "=========================================="
echo " Qwen Voice AI - ALL SERVICES READY"
echo "=========================================="
echo
echo "Services:"
echo "  vLLM:      http://127.0.0.1:8000"
echo "  WebSocket: http://127.0.0.1:8001"
echo
echo "The current public WSS URL is shown above."
echo
echo "IMPORTANT:"
echo "Quick Tunnel URLs change after a Kaggle runtime reset."
echo "Update QWEN_WS_URL in Voice AI Lab when the URL changes."
echo
