
import asyncio
import json
import os
import time
from typing import Any

import httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import uvicorn


# ============================================================
# Configuration
# ============================================================

VLLM_BASE_URL = os.getenv("VLLM_BASE_URL", "http://127.0.0.1:8000")
VLLM_CHAT_URL = f"{VLLM_BASE_URL.rstrip('/')}/v1/chat/completions"

HOST = os.getenv("BRIDGE_HOST", "0.0.0.0")
PORT = int(os.getenv("BRIDGE_PORT", "8001"))

DEFAULT_MODEL = os.getenv("QWEN_MODEL", "Qwen/Qwen3.5-4B")

SYSTEM_PROMPT = """You are a realtime voice assistant.
Return ONLY the final answer to the user.
Do not output thinking, reasoning, analysis, planning, drafts, alternatives, or explanations of your reasoning.
Keep the response concise and natural for speech."""


app = FastAPI(title="Qwen Voice AI WebSocket Bridge")


# ============================================================
# Helpers
# ============================================================

async def stream_vllm_chat(
    messages: list[dict[str, Any]],
    temperature: float = 0.7,
    max_tokens: int | None = None,
):
    """Stream tokens from the local vLLM OpenAI-compatible API."""

    payload: dict[str, Any] = {
        "model": DEFAULT_MODEL,
        "messages": messages,
        "temperature": temperature,
        "stream": True,

        # Qwen3.5 thinking is disabled for realtime voice.
        "chat_template_kwargs": {
            "enable_thinking": False,
        },
    }

    # vLLM handles omitted max_tokens better than null.
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens

    timeout = httpx.Timeout(
        connect=10.0,
        read=None,
        write=30.0,
        pool=30.0,
    )

    async with httpx.AsyncClient(timeout=timeout) as client:
        async with client.stream(
            "POST",
            VLLM_CHAT_URL,
            json=payload,
        ) as response:

            response.raise_for_status()

            async for line in response.aiter_lines():
                if not line:
                    continue

                if line.startswith("data: "):
                    data = line[6:]

                    if data == "[DONE]":
                        break

                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue

                    choices = chunk.get("choices") or []
                    if not choices:
                        continue

                    delta = choices[0].get("delta") or {}
                    text = delta.get("content")

                    if text:
                        yield text


# ============================================================
# WebSocket endpoint
# ============================================================

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()

    print("[WS] Client connected")

    try:
        while True:
            raw = await websocket.receive_text()

            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                await websocket.send_json({
                    "type": "error",
                    "error": "Invalid JSON",
                })
                continue

            message_type = message.get("type")

            # ------------------------------------------------
            # Legacy compatibility
            # ------------------------------------------------

            if message_type == "start":
                await websocket.send_json({
                    "type": "ready",
                })
                continue

            # ------------------------------------------------
            # Actual qwen_ws protocol
            # ------------------------------------------------

            if message_type == "chat":

                request_id = message.get("request_id")

                if not request_id:
                    request_id = f"bridge-{time.time_ns()}"

                incoming_messages = message.get("messages")

                if not isinstance(incoming_messages, list):
                    await websocket.send_json({
                        "type": "error",
                        "request_id": request_id,
                        "error": "messages must be a list",
                    })
                    continue

                # Preserve the messages supplied by Voice AI Lab.
                # If there is no system message, provide the
                # realtime voice system instruction.
                messages = list(incoming_messages)

                if not any(
                    isinstance(m, dict) and m.get("role") == "system"
                    for m in messages
                ):
                    messages.insert(
                        0,
                        {
                            "role": "system",
                            "content": SYSTEM_PROMPT,
                        },
                    )

                temperature = message.get("temperature", 0.7)

                if temperature is None:
                    temperature = 0.7

                max_tokens = message.get("max_tokens")

                started_at = time.perf_counter()
                first_token_at = None

                await websocket.send_json({
                    "type": "start",
                    "request_id": request_id,
                })

                try:
                    async for token in stream_vllm_chat(
                        messages=messages,
                        temperature=float(temperature),
                        max_tokens=max_tokens,
                    ):

                        if first_token_at is None:
                            first_token_at = time.perf_counter()

                            await websocket.send_json({
                                "type": "timing",
                                "event": "first_token",
                                "request_id": request_id,
                                "ttft": (
                                    first_token_at - started_at
                                ),
                            })

                        await websocket.send_json({
                            "type": "token",
                            "request_id": request_id,
                            "text": token,
                        })

                    completed_at = time.perf_counter()

                    await websocket.send_json({
                        "type": "timing",
                        "event": "complete",
                        "request_id": request_id,
                        "total_time": completed_at - started_at,
                    })

                    # IMPORTANT:
                    # qwen_ws waits for this terminal frame.
                    await websocket.send_json({
                        "type": "done",
                        "request_id": request_id,
                    })

                except asyncio.CancelledError:
                    raise

                except Exception as exc:
                    print(
                        f"[WS] Request {request_id} failed: {exc}"
                    )

                    await websocket.send_json({
                        "type": "error",
                        "request_id": request_id,
                        "error": str(exc),
                    })

                continue

            # ------------------------------------------------
            # Legacy text protocol
            # ------------------------------------------------

            if message_type in {
                "text",
                "user_message",
                "transcript",
            }:

                text = (
                    message.get("text")
                    or message.get("user_message")
                    or message.get("transcript")
                    or ""
                )

                if not text:
                    await websocket.send_json({
                        "type": "error",
                        "error": "No text supplied",
                    })
                    continue

                request_id = message.get(
                    "request_id",
                    f"legacy-{time.time_ns()}",
                )

                messages = [
                    {
                        "role": "system",
                        "content": SYSTEM_PROMPT,
                    },
                    {
                        "role": "user",
                        "content": text,
                    },
                ]

                started_at = time.perf_counter()
                first_token_at = None

                await websocket.send_json({
                    "type": "start",
                    "request_id": request_id,
                })

                try:
                    async for token in stream_vllm_chat(
                        messages=messages,
                        temperature=0.7,
                        max_tokens=None,
                    ):

                        if first_token_at is None:
                            first_token_at = time.perf_counter()

                            await websocket.send_json({
                                "type": "timing",
                                "event": "first_token",
                                "request_id": request_id,
                                "ttft": (
                                    first_token_at - started_at
                                ),
                            })

                        await websocket.send_json({
                            "type": "token",
                            "request_id": request_id,
                            "text": token,
                        })

                    completed_at = time.perf_counter()

                    await websocket.send_json({
                        "type": "timing",
                        "event": "complete",
                        "request_id": request_id,
                        "total_time": completed_at - started_at,
                    })

                    await websocket.send_json({
                        "type": "done",
                        "request_id": request_id,
                    })

                except Exception as exc:
                    await websocket.send_json({
                        "type": "error",
                        "request_id": request_id,
                        "error": str(exc),
                    })

                continue

            # ------------------------------------------------
            # Unknown message
            # ------------------------------------------------

            await websocket.send_json({
                "type": "error",
                "request_id": message.get("request_id"),
                "error": f"Unknown message type: {message_type}",
            })

    except WebSocketDisconnect:
        print("[WS] Client disconnected")

    except Exception as exc:
        print(f"[WS] Connection error: {exc}")


# ============================================================
# HTTP health endpoint
# ============================================================

@app.get("/")
async def health():
    return {
        "status": "ok",
        "service": "qwen-voice-ai-websocket-bridge",
        "model": DEFAULT_MODEL,
        "vllm": VLLM_BASE_URL,
        "websocket": "/ws",
    }


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":
    uvicorn.run(
        app,
        host=HOST,
        port=PORT,
    )
