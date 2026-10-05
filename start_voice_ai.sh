#!/usr/bin/env bash
set -e

BASE="/kaggle/working/qwen-voice-ai-kaggle"
VENV="$BASE/vllm-env"
VLLM_PY="$VENV/bin/python"

MODEL="Qwen/Qwen3.5-4B"
VLLM_PORT=8000
BRIDGE_PORT=8001

echo "=========================================="
echo " Qwen Voice AI - Kaggle Startup"
echo "=========================================="

echo "[1/3] Checking vLLM environment..."

if [ ! -x "$VLLM_PY" ]; then
    echo "ERROR: vLLM environment not found."
    echo "Run setup_voice_ai.sh first."
    exit 1
fi

echo "Python:"
"$VLLM_PY" --version

echo
echo "[2/3] Starting vLLM..."

if curl -s "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
    echo "vLLM is already running."
else
    echo "Starting Qwen3.5-4B..."

    nohup "$VLLM_PY" -m vllm.entrypoints.openai.api_server         --model "$MODEL"         --host 0.0.0.0         --port "$VLLM_PORT"         --tensor-parallel-size 2         --dtype half         --enforce-eager         --max-model-len 8192 \
        > "$BASE/vllm.log" 2>&1 &

    VLLM_PID=$!

    echo "vLLM PID: $VLLM_PID"
    echo "Waiting for vLLM..."

    for i in {1..120}; do
        if curl -s "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
            echo "vLLM is ready."
            break
        fi

        if ! kill -0 "$VLLM_PID" 2>/dev/null; then
            echo "ERROR: vLLM process exited."
            tail -100 "$BASE/vllm.log" || true
            exit 1
        fi

        sleep 2
    done

    if ! curl -s "http://127.0.0.1:${VLLM_PORT}/v1/models" >/dev/null 2>&1; then
        echo "ERROR: vLLM did not become ready."
        tail -100 "$BASE/vllm.log" || true
        exit 1
    fi
fi

echo
echo "[3/3] Starting WebSocket bridge..."

if curl -s "http://127.0.0.1:${BRIDGE_PORT}/" >/dev/null 2>&1; then
    echo "WebSocket bridge is already running."
else
    nohup "$VLLM_PY" "$BASE/ws_bridge.py"         > "$BASE/ws_bridge.log" 2>&1 &

    BRIDGE_PID=$!

    echo "Bridge PID: $BRIDGE_PID"

    sleep 3

    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        echo "ERROR: WebSocket bridge failed to start."
        tail -100 "$BASE/ws_bridge.log" || true
        exit 1
    fi

    echo "WebSocket bridge started."
fi

echo
echo "=========================================="
echo " Qwen Voice AI services are running"
echo "=========================================="
echo
echo "vLLM: http://127.0.0.1:${VLLM_PORT}"
echo "WebSocket: ws://127.0.0.1:${BRIDGE_PORT}/ws"
echo
echo "Logs:"
echo "  $BASE/vllm.log"
echo "  $BASE/ws_bridge.log"
