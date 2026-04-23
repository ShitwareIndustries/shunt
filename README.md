# shunt

**LLM load balancer**

[![License: AGPL v3](https://img.shields.io/badge/license-AGPL%20v3-dc143c.svg)](LICENSE)

shunt sits between your application and multiple LLM backends. It routes requests by model group with round-robin distribution, health-checks each backend, and passes SSE streaming through unchanged. Swap your base URL — nothing else changes.

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

That is it. Point your OpenAI client at `http://localhost:8080` and you are load balancing.

See [config.example.toml](config.example.toml) for the full set of options.

## How it works

shunt groups backends by model name. When a request arrives for `llama3`, it picks the next healthy backend in that group's round-robin rotation.

- **Model-group routing** — each model gets its own backend pool, round-robin within the group
- **Health checking** — every backend gets polled at a configurable interval; three consecutive failures marks it unhealthy and it stops receiving traffic
- **SSE passthrough** — `text/event-stream` responses stream through without buffering, so chat completions work without modification
- **Request queue with backpressure** — if all backends are busy, requests queue up with a configurable cap and timeout

Endpoints are OpenAI-compatible: `/v1/chat/completions`, `/v1/completions`, `/v1/models`, and `/health`.

## Configuration

### Config file (TOML)

```toml
[balancer]
listen_addr = "0.0.0.0:8080"       # address shunt listens on
health_check_interval_ms = 2000     # how often to ping backends
max_buffered_requests = 64          # queue cap before rejecting
buffered_request_timeout_ms = 30000 # how long a queued request waits
log_level = "info"                  # debug, info, warn, error

[[models]]
id = "llama3-primary"               # arbitrary identifier
address = "http://127.0.0.1:8081"   # backend URL
model = "llama3"                    # model name for routing group
```

Add more `[[models]]` entries for additional backends.

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

## Roadmap

- **KV-cache reuse routing** — route requests to the backend with the best KV-cache hit rate, cutting prefill compute for repeated contexts ([technical writeup](docs/marketing/blog-kv-cache-reuse-routing.md))
- **Docker containerization** — single-container deployment with health checks
- **Benchmark suite** — latency and throughput comparisons under load
- **Multiple routing strategies** — least-connections, weighted round-robin, adaptive

## License

shunt is released under the [GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.en.html). A `LICENSE` file will be added to this repository.

---

Shitware Industries. Ship it. We dare you.
