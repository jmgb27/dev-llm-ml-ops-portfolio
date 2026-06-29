# Edge LLM Demo (Chat UI)

A lightweight FastAPI proxy and static chat frontend for the LiteLLM gateway — a **live demo** of the inference stack, not a production chat product.

## Disclaimer

**Demo / portfolio use only.** This UI fronts a **Llama 3.2 1B** model running on **edge homelab hardware** (K3s on Proxmox). Inference is deliberately constrained by available RAM and CPU on worker nodes:

- **Small model** — a 1B-parameter model can be **inaccurate or hallucinate**, especially on long or complex prompts.
- **Limited context** — the context window is capped (default 4K tokens) for stability on edge hardware; older turns are auto-summarized when the limit is approached.
- **Not production-grade** — no persistence, auth, or SLA. Suitable for demonstrating the gateway stack, not as a user-facing product.

## Features

- Streaming token rendering with markdown and code-block support
- Multi-turn conversation history (client-side session)
- Light/dark theme
- Error handling for 401, 429, and upstream timeouts

## Local development

### With Docker Compose (recommended)

From the repo root:

```bash
docker compose up --build
```

Open **http://localhost:8000**

### Standalone (proxy only)

Requires a running LiteLLM instance (e.g. `docker compose up litellm-gateway`).

```bash
cd chat-ui
pip install -r requirements.txt
export LITELLM_BASE_URL=http://localhost:4000
export LITELLM_API_KEY=sk-1234
export LITELLM_MODEL=llama3
uvicorn app.main:app --reload --port 8000
```

## Kubernetes

**Standard path:** CI (`.github/workflows/ci.yaml`) builds and publishes `chat-ui:<git-sha>` to your private registry on merge to `master`. ArgoCD syncs the tag from `k8s/kustomization.yaml`; the registry host is configured in `ansible/group_vars/secrets.yml` (not in Git).

One-time on the cluster:

```bash
./scripts/apply-registry-secret.sh   # REGISTRY_USERNAME / REGISTRY_PASSWORD in .env
```

Manual push (same registry, e.g. for hotfixes):

```bash
./scripts/deploy-chat-ui.sh
```

After deploy:

```bash
./scripts/cluster.sh port-forward chat-ui
# or: kubectl -n llm-gateway port-forward svc/chat-ui 8000:8000
```

Open **http://localhost:8000**

## API

| Endpoint      | Method | Description                     |
| ------------- | ------ | ------------------------------- |
| `/`           | GET    | Chat UI                         |
| `/healthz`    | GET    | Health check                    |
| `/api/config` | GET    | Public config (model name)      |
| `/api/chat`   | POST   | Streaming chat proxy to LiteLLM |

### POST `/api/chat`

```json
{
    "messages": [{ "role": "user", "content": "Hello" }]
}
```

Returns `text/event-stream` with OpenAI-compatible SSE chunks forwarded from LiteLLM.

## Tests

```bash
cd chat-ui
pip install -r requirements.txt
pytest
```

## Environment variables

| Variable           | Default                 | Description                    |
| ------------------ | ----------------------- | ------------------------------ |
| `LITELLM_BASE_URL` | `http://localhost:4000` | LiteLLM gateway URL            |
| `LITELLM_API_KEY`  | `sk-1234`               | Bearer token for LiteLLM       |
| `LITELLM_MODEL`    | `llama3`                | Model alias                    |
| `UPSTREAM_TIMEOUT` | `180`                   | Upstream request timeout (sec) |
