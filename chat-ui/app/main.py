"""FastAPI proxy + static chat UI for the LiteLLM gateway."""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import AsyncIterator

import httpx
from fastapi import FastAPI
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000").rstrip(
    "/"
)
LITELLM_API_KEY = os.environ.get("LITELLM_API_KEY", "sk-1234")
LITELLM_MODEL = os.environ.get("LITELLM_MODEL", "llama3")
UPSTREAM_TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "180"))

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="Edge LLM Demo", version="1.0.0")


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(..., min_length=1)


def _sse_error(message: str) -> str:
    return f"data: {json.dumps({'error': message})}\n\n"


def _extract_upstream_error(body: bytes, status_code: int) -> str:
    default = f"Upstream error ({status_code})."
    if not body:
        return default
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        text = body.decode(errors="replace").strip()
        return text[:300] if text else default

    error = payload.get("error")
    if isinstance(error, dict):
        message = error.get("message") or error.get("detail")
        if message:
            return str(message)
    if isinstance(error, str):
        return error

    message = payload.get("message") or payload.get("detail")
    if message:
        return str(message)

    return default


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/config")
async def config() -> dict[str, str]:
    """Expose non-secret client config."""
    return {"model": LITELLM_MODEL}


@app.post("/api/chat")
async def chat(request: ChatRequest) -> StreamingResponse:
    payload = {
        "model": LITELLM_MODEL,
        "messages": [message.model_dump() for message in request.messages],
        "stream": True,
    }
    headers = {
        "Authorization": f"Bearer {LITELLM_API_KEY}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }

    async def stream() -> AsyncIterator[str]:
        try:
            async with httpx.AsyncClient(timeout=UPSTREAM_TIMEOUT) as client:
                async with client.stream(
                    "POST",
                    f"{LITELLM_BASE_URL}/v1/chat/completions",
                    json=payload,
                    headers=headers,
                ) as response:
                    if response.status_code == 401:
                        yield _sse_error("Unauthorized: invalid upstream API key.")
                        return
                    if response.status_code == 429:
                        yield _sse_error(
                            "Rate limit exceeded. Please wait and try again."
                        )
                        return
                    if response.status_code >= 400:
                        body = await response.aread()
                        detail = _extract_upstream_error(body, response.status_code)
                        logger.warning(
                            "LiteLLM returned %s: %s",
                            response.status_code,
                            detail,
                        )
                        yield _sse_error(detail)
                        return

                    async for line in response.aiter_lines():
                        if line:
                            yield f"{line}\n"
                        else:
                            yield "\n"
        except httpx.TimeoutException:
            yield _sse_error("Request timed out. The model may be overloaded.")
        except httpx.RequestError:
            logger.exception("Upstream request failed")
            yield _sse_error("Cannot reach LLM gateway. Is LiteLLM running?")

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


if STATIC_DIR.is_dir():
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
