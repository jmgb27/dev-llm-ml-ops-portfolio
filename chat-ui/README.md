# Chat UI

A lightweight FastAPI proxy and static chat frontend for the LiteLLM gateway. The browser talks to `/api/chat` on this service; the LiteLLM API key stays server-side and responses stream via SSE.

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

Build for **linux/amd64** (cluster nodes are Intel x86, not ARM):

```bash
# One-command deploy (build, import image, apply manifest)
./scripts/deploy-chat-ui.sh
```

Or manually:

```bash
docker build --platform linux/amd64 -t chat-ui:latest ./chat-ui
docker save chat-ui:latest -o /tmp/chat-ui-amd64.tar
scp /tmp/chat-ui-amd64.tar ubuntu@192.168.100.71:/tmp/
ssh ubuntu@192.168.100.71 'sudo k3s ctr -n k8s.io images import /tmp/chat-ui-amd64.tar'
kubectl apply -f k8s/webui/chat-ui-deploy.yaml
```

The manifest uses `imagePullPolicy: Never` so K3s uses the locally imported image.

After deploy:

```bash
./scripts/cluster.sh port-forward chat-ui
# or: kubectl -n llm-gateway port-forward svc/chat-ui 8000:8000
```

Open **http://localhost:8000**

## API

| Endpoint       | Method | Description                          |
| -------------- | ------ | ------------------------------------ |
| `/`            | GET    | Chat UI                              |
| `/healthz`     | GET    | Health check                         |
| `/api/config`  | GET    | Public config (model name)           |
| `/api/chat`    | POST   | Streaming chat proxy to LiteLLM      |

### POST `/api/chat`

```json
{
  "messages": [
    { "role": "user", "content": "Hello" }
  ]
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

| Variable            | Default                  | Description                    |
| ------------------- | ------------------------ | ------------------------------ |
| `LITELLM_BASE_URL`  | `http://localhost:4000`  | LiteLLM gateway URL            |
| `LITELLM_API_KEY`   | `sk-1234`                | Bearer token for LiteLLM       |
| `LITELLM_MODEL`     | `llama3`                 | Model alias                    |
| `UPSTREAM_TIMEOUT`  | `180`                    | Upstream request timeout (sec) |
