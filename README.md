# shunt

**LLM load balancer**

[![License: AGPL v3](https://img.shields.io/badge/license-AGPL%20v3-dc143c.svg)](LICENSE)

shunt sits between your application and multiple LLM backends. It routes requests by model group, prefers backends with cached KV-state for repeated prefixes (cache-affinity routing), falls back to least-connections, health-checks each backend, and passes SSE streaming through unchanged. Swap your base URL — nothing else changes.

## Quick start

```sh
curl -LO https://github.com/ShitwareIndustries/shunt/releases/latest/download/shunt-linux-x86_64
chmod +x shunt-linux-x86_64
```

Create a config file:

```toml
[balancer]
listen_addr = "0.0.0.0:8080"

[[models]]
id = "primary"
address = "http://127.0.0.1:8081"
model = "llama3"

[[models]]
id = "secondary"
address = "http://127.0.0.1:8082"
model = "llama3"
```

Run it:

```sh
./shunt-linux-x86_64 --config=config.toml
```

Make sure you have at least one LLM backend running on the configured ports (e.g., llama.cpp on port 8081).

That is it. Point your OpenAI client at `http://localhost:8080` and you are load balancing. Verify with:

```sh
curl http://localhost:8080/v1/models
```

See [config.example.toml](config.example.toml) for the full set of options.

## How it works

shunt groups backends by model name. When a request arrives for `llama3`, it picks the best healthy backend in that group.

- **KV-cache reuse routing** — shunt hashes the prompt prefix and routes to the backend that already has it cached. Cache hit = skip up to 90% of prefill compute. No cache match? Falls back to least-connections.
- **Model-group routing** — each model gets its own backend pool
- **Health checking** — every backend gets polled at a configurable interval; three consecutive failures marks it unhealthy and it stops receiving traffic
- **SSE passthrough** — `text/event-stream` responses stream through without buffering, so chat completions work without modification
- **Request queue with backpressure** — if all backends are busy, requests queue up with a configurable cap and timeout

Endpoints are OpenAI-compatible: `/v1/chat/completions`, `/v1/completions`, `/v1/models`, and `/health`.

## Configuration

### Config file (TOML)

```toml
[balancer]
listen_addr = "0.0.0.0:8080" # address shunt listens on
health_check_interval_ms = 2000 # how often to ping backends
max_buffered_requests = 64 # queue cap before rejecting
buffered_request_timeout_ms = 30000 # how long a queued request waits
log_level = "info" # debug, info, warn, error

[[models]]
id = "llama3-primary" # arbitrary identifier
address = "http://127.0.0.1:8081" # backend URL
model = "llama3" # model name for routing group
```

Add more `[[models]]` entries for additional backends.

### Backend types

Each model entry supports an optional `backend_type` field that controls health-check behavior and default timeouts:

| `backend_type` | Health endpoint | Health response | Connect timeout | Request timeout |
|----------------|----------------|-----------------|-----------------|-----------------|
| `llama_cpp` (default) | `/health` | slot info JSON | 5 s | 30 s |
| `vllm` | `/health` | `{"status":"ok"}` or `{"status":"running"}` | 10 s | 120 s |
| `openai` | `/v1/models` | HTTP status only | 10 s | 60 s |

```toml
# llama.cpp backend (default, backend_type can be omitted)
[[models]]
id = "llama3-primary"
address = "http://127.0.0.1:8081"
model = "llama3"

# vLLM backend
[[models]]
id = "vllm-primary"
address = "http://127.0.0.1:8000"
model = "llama3"
backend_type = "vllm"

# OpenAI-compatible remote backend
[[models]]
id = "openai-remote"
address = "https://api.openai.com"
model = "gpt-4"
backend_type = "openai"
```

vLLM backends use longer timeouts by default (10 s connect, 120 s request) because inference on large models can take longer to start and complete. OpenAI remote backends also use longer connect timeouts due to network latency.

### CLI flags

| Flag | Env variable | Default | Description |
|------|-------------|---------|-------------|
| `--config=<path>` | `LB_CONFIG` | none | path to TOML config |
| `--listen-addr=<addr>` | `LB_LISTEN_ADDR` | `0.0.0.0:8080` | listen address |
| `--health-check-interval=<ms>` | `LB_HEALTH_CHECK_INTERVAL` | `2000` | health check interval |
| `--max-buffered-requests=<n>` | `LB_MAX_BUFFERED_REQUESTS` | `64` | queue capacity |
| `--buffered-request-timeout=<ms>` | `LB_BUFFERED_REQUEST_TIMEOUT` | `30000` | queue timeout |
| `--log-level=<level>` | `LB_LOG_LEVEL` | `info` | log level |

CLI flags override config file values. Env variables override CLI flags.

## Building from source

Requires [Zig](https://ziglang.org/) 0.16.0 or later.

```sh
zig build
```

The binary lands at `zig-out/bin/shunt`.

Cross-compile:

```sh
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-gnu
```

## Docker

Build and run with Docker:

```sh
docker build -t shunt .
```

Run with a mounted config file:

```sh
docker run -d \
  --name shunt \
  -p 8080:8080 \
  -v $(pwd)/config.toml:/etc/shunt/config.toml:ro \
  -e LB_CONFIG=/etc/shunt/config.toml \
  shunt
```

Run with environment variables instead of a config file:

```sh
docker run -d \
  --name shunt \
  -p 8080:8080 \
  -e LB_LISTEN_ADDR=0.0.0.0:8080 \
  -e LB_LOG_LEVEL=info \
  shunt
```

The image includes a Docker `HEALTHCHECK` that probes `/health` every 30 seconds. Check health status:

```sh
docker inspect --format='{{.State.Health.Status}}' shunt
```

Blue-green deployment with Caddy:

```sh
docker compose up -d
```

The image runs as a non-root user (`shunt`) and is built on Alpine 3.21 for minimal size with healthcheck support.

## Roadmap

### v0.2.0 (shipped)

- **Docker containerization** — multi-stage alpine build, ~4.2MB image
- **Benchmark suite** — latency and throughput comparisons under load
- **vLLM backend support** — dedicated health checks, extended timeouts
- **Multiple routing strategies** — least-connections, weighted, random, latency-based

### v0.3.0 (planned)

- **TLS/HTTPS support** — native TLS termination
- **Config hot-reload** — SIGHUP to reload backends without restart
- **Admin API** — runtime backend add/remove, metrics export

## License

shunt is released under the [GNU Affero General Public License v3.0](LICENSE).

---

Shitware Industries. Ship it. We dare you.
