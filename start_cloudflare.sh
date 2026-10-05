#!/usr/bin/env bash
set -e

BASE="/kaggle/working/qwen-voice-ai-kaggle"
CLOUDFLARED="$BASE/cloudflared"
BRIDGE_PORT=8001
LOG="$BASE/cloudflared.log"

echo "=========================================="
echo " Qwen Voice AI - Cloudflare Startup"
echo "=========================================="

echo "[1/3] Checking cloudflared..."

if [ ! -x "$CLOUDFLARED" ]; then
    echo "cloudflared not found. Downloading..."

    curl -L \
        --fail \
        --silent \
        --show-error \
        -o "$CLOUDFLARED" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"

    chmod +x "$CLOUDFLARED"
fi

echo "cloudflared:"
"$CLOUDFLARED" --version

echo
echo "[2/3] Checking WebSocket bridge..."

if ! curl -s "http://127.0.0.1:${BRIDGE_PORT}/" >/dev/null 2>&1; then
    echo "ERROR: WebSocket bridge is not running on port ${BRIDGE_PORT}."
    echo "Start start_voice_ai.sh first."
    exit 1
fi

echo "WebSocket bridge is ready."

echo
echo "[3/3] Starting Cloudflare Quick Tunnel..."

if pgrep -f "$CLOUDFLARED tunnel --url" >/dev/null 2>&1; then
    echo "Cloudflare tunnel is already running."
else
    rm -f "$LOG"

    nohup "$CLOUDFLARED" tunnel \
        --url "http://127.0.0.1:${BRIDGE_PORT}" \
        --no-autoupdate \
        > "$LOG" 2>&1 &

    CLOUDFLARED_PID=$!

    echo "Cloudflare PID: $CLOUDFLARED_PID"

    echo "Waiting for tunnel URL..."

    TUNNEL_URL=""

    for i in {1..30}; do
        TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$LOG" | head -1 || true)

        if [ -n "$TUNNEL_URL" ]; then
            break
        fi

        if ! kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
            echo "ERROR: Cloudflare process exited."
            tail -100 "$LOG" || true
            exit 1
        fi

        sleep 2
    done

    if [ -z "$TUNNEL_URL" ]; then
        echo "ERROR: Could not find Cloudflare tunnel URL."
        tail -100 "$LOG" || true
        exit 1
    fi
fi

TUNNEL_URL=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$LOG" | head -1 || true)

if [ -z "$TUNNEL_URL" ]; then
    echo "ERROR: Cloudflare tunnel URL not found."
    tail -50 "$LOG" || true
    exit 1
fi

WSS_URL="${TUNNEL_URL/https:/wss:}"

echo
echo "=========================================="
echo " Cloudflare Tunnel is READY"
echo "=========================================="
echo
echo "HTTP:"
echo "  $TUNNEL_URL"
echo
echo "WebSocket:"
echo "  ${WSS_URL}/ws"
echo
echo "Use this in Voice AI Lab:"
echo "  QWEN_WS_URL=${WSS_URL}/ws"
echo
echo "Log:"
echo "  $LOG"
echo
