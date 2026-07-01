# LLM Gateway — test suite

Executable tests for the port-forwarded LiteLLM API and optional Kubernetes chaos scenarios. See the [root README](../../README.md#documentation-map) for how this fits the overall stack.

## Prerequisites

**Terminal 1** — port-forward (cluster):

```bash
kubectl -n llm-gateway port-forward svc/litellm 4000:4000
```

**Terminal 2** — run tests:

```bash
chmod +x scripts/tests/*.sh scripts/tests/chaos/*.sh scripts/tests/run-all.sh
./scripts/tests/run-all.sh
```

For **Docker Compose** instead of K3s:

```bash
docker compose up -d
export LITELLM_BASE_URL=http://localhost:4000
./scripts/tests/run-all.sh
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LITELLM_BASE_URL` | `http://localhost:4000` | Gateway base URL |
| `LITELLM_API_KEY` | `sk-1234` | Bearer token |
| `LITELLM_MODEL` | `llama3` | Model name |
| `RATE_LIMIT_BURST` | `70` | Parallel requests for rate-limit test |
| `LOAD_SPIKE_CONCURRENCY` | `50` | Concurrent requests for load spike |
| `LOAD_SPIKE_MIN_SUCCESS_PCT` | `80` | Minimum % of 200 responses |
| `FAILOVER_WORKER_NODE` | `k3s-worker-01` | Worker to kill in failover test |
| `PROBE_INTERVAL_SEC` | `1` | Seconds between overlapping chat probes during chaos |
| `PROBE_WARMUP_SEC` | `5` | Steady traffic before injecting failure |
| `PROBE_POST_CHAOS_SEC` | `20` | Keep probing after pod delete through recovery |
| `CONFIRM_CHAOS` | — | Set to `yes` for destructive hardware test |

## Test catalog

### Safe API tests (no cluster changes)

| Script | Scenario | Pass criteria |
|--------|----------|---------------|
| `01-smoke.sh` | Basic availability | `/health/liveliness` 200, chat returns content |
| `02-auth-perimeter.sh` | API key enforcement | 401 without key; 400/401 with invalid key; 200 with valid key |
| `04-load-spike.sh` | Redis queue under burst | 50 concurrent, no `502`; ≥80% `200` or backpressure via `429` |
| `03-rate-limit.sh` | RPM perimeter (`rpm: 60`) | Burst of 70 → at least one `429` *(runs after load spike)* |

### Chaos tests (`--chaos`, needs `kubectl`)

| Script | Enterprise scenario | What it does |
|--------|---------------------|--------------|
| `chaos/05-worker-failover.sh` | Worker node failure | Continuous chat traffic **before** pod delete; no `502` during failover |
| `chaos/06-hardware-constraint.sh` | AVX2 / SIGILL | Removes `cpu-feature=avx2` selector; expects crash on master; restores |
| `chaos/07-pod-kill-recovery.sh` | Self-healing | Continuous traffic through pod kill; Deployment recreates pod |

Run chaos suite:

```bash
./scripts/tests/run-all.sh --chaos
```

Destructive hardware test requires explicit confirmation:

```bash
CONFIRM_CHAOS=yes ./scripts/tests/chaos/06-hardware-constraint.sh
```

## Run individual tests

```bash
./scripts/tests/01-smoke.sh
./scripts/tests/03-rate-limit.sh
./scripts/tests/chaos/05-worker-failover.sh
```

## GitOps drift (manual)

ArgoCD drift reconciliation is not automated here (requires ArgoCD installed). To validate manually:

```bash
kubectl -n llm-gateway delete pod -l app=llama-cpp
# With ArgoCD: pod/config reverts from Git within seconds
kubectl get applications -n argocd
```

## Expected architecture under test

```text
curl → localhost:4000 (port-forward)
         → LiteLLM (auth, rpm/tpm, Redis queue)
         → llama-cpp Service
         → Istio Waypoint (LEAST_REQUEST)
         → llama.cpp on AVX2 workers
```

Rate limits and queueing are enforced by **LiteLLM**; inference load balancing across replicas is enforced by **Istio**.
