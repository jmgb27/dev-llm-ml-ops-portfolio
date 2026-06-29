"""Tests for the chat-ui FastAPI proxy."""

from __future__ import annotations

import json
from typing import AsyncIterator
from unittest.mock import patch

import httpx
import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


class FakeStreamResponse:
    def __init__(self, status_code: int = 200, lines: list[str] | None = None) -> None:
        self.status_code = status_code
        self._lines = lines or []

    async def __aenter__(self) -> FakeStreamResponse:
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    def aiter_lines(self) -> AsyncIterator[str]:
        async def _gen() -> AsyncIterator[str]:
            for line in self._lines:
                yield line

        return _gen()

    async def aread(self) -> bytes:
        return b"upstream error"


class FakeAsyncClient:
    def __init__(self, response: FakeStreamResponse) -> None:
        self.response = response
        self.last_request: dict | None = None

    async def __aenter__(self) -> FakeAsyncClient:
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    def stream(self, method: str, url: str, **kwargs: object) -> FakeStreamResponse:
        self.last_request = {
            "method": method,
            "url": url,
            "json": kwargs.get("json"),
            "headers": kwargs.get("headers"),
        }
        return self.response


@pytest.mark.asyncio
async def test_healthz() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.asyncio
async def test_config_exposes_model() -> None:
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/config")
    assert response.status_code == 200
    assert "model" in response.json()


@pytest.mark.asyncio
async def test_chat_forwards_messages_and_injects_key() -> None:
    lines = [
        'data: {"choices":[{"delta":{"content":"Hello"}}]}',
        "data: [DONE]",
    ]
    fake_client = FakeAsyncClient(FakeStreamResponse(lines=lines))

    with patch("app.main.httpx.AsyncClient", return_value=fake_client):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.post(
                "/api/chat",
                json={"messages": [{"role": "user", "content": "Hi"}]},
            )

    assert response.status_code == 200
    assert fake_client.last_request is not None
    assert fake_client.last_request["url"].endswith("/v1/chat/completions")
    assert fake_client.last_request["json"]["stream"] is True
    assert fake_client.last_request["json"]["messages"] == [
        {"role": "user", "content": "Hi"}
    ]
    assert fake_client.last_request["headers"]["Authorization"].startswith("Bearer ")

    body = ""
    async for chunk in response.aiter_text():
        body += chunk
    assert "Hello" in body


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("status_code", "expected_fragment"),
    [
        (401, "Unauthorized"),
        (429, "Rate limit"),
        (500, "upstream error"),
    ],
)
async def test_chat_maps_upstream_errors(
    status_code: int, expected_fragment: str
) -> None:
    fake_client = FakeAsyncClient(FakeStreamResponse(status_code=status_code))

    with patch("app.main.httpx.AsyncClient", return_value=fake_client):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.post(
                "/api/chat",
                json={"messages": [{"role": "user", "content": "Hi"}]},
            )

    body = ""
    async for chunk in response.aiter_text():
        body += chunk

    payload = json.loads(body.split("data: ", 1)[1].strip())
    assert expected_fragment in payload["error"]


@pytest.mark.asyncio
async def test_chat_handles_timeout() -> None:
    class TimeoutClient:
        async def __aenter__(self) -> TimeoutClient:
            return self

        async def __aexit__(self, *args: object) -> None:
            return None

        def stream(self, *args: object, **kwargs: object) -> None:
            raise httpx.TimeoutException("timed out")

    with patch("app.main.httpx.AsyncClient", return_value=TimeoutClient()):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as client:
            response = await client.post(
                "/api/chat",
                json={"messages": [{"role": "user", "content": "Hi"}]},
            )

    body = ""
    async for chunk in response.aiter_text():
        body += chunk

    payload = json.loads(body.split("data: ", 1)[1].strip())
    assert "timed out" in payload["error"].lower()
