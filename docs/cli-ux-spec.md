# shunt CLI — User Experience Specification

> UX specification for the shunt command-line interface.
> Follows the product brand style guide at `/root/shunt/design/brand-style-guide.md`.

---

## 1. Design Principles

1. **CLI is the product** — shunt lives in the terminal. The CLI is not a wrapper around an API; it is the primary interface.
2. **Zero-config for the simple case** — one backend, one command. `shunt run` with no config file should work.
3. **Explicit config for the real case** — multi-backend routing requires a config file, and the tooling around that config must be excellent.
4. **Actionable errors** — every error message tells the user exactly what to do next. No "invalid config", only "invalid config: `backends[2].model` is required but missing. Add a model field to your third backend entry in shunt.yaml".
5. **Modern dev tool aesthetic** — shunt should feel like rg, fd, jq, delta: fast, quiet when things work, loud when they don't, beautifully formatted when you ask for it.
6. **"shunt" always lowercase** — in all help text, error messages, config comments, and documentation.

---

## 2. Command Structure

### 2.1 Top-Level Command

```
$ shunt [OPTIONS] <SUBCOMMAND>
```

Running `shunt` with no subcommand prints a short help summary (not an error). Running `shunt --help` prints the full help.

### 2.2 Subcommands

| Subcommand | Purpose | Aliases |
|------------|---------|---------|
| `run` | Start the load balancer proxy | (default) |
| `config` | Validate, generate, or print the config | `cfg` |
| `backends` | List and test backend connectivity | `be` |
| `status` | Show live health and routing status | `st` |
| `version` | Print version, build info, Zig version | `ver` |

### 2.3 Command Hierarchy

```
shunt
├── run          Start the proxy server
├── config
│   ├── check    Validate shunt.yaml and report errors
│   ├── init     Generate a starter shunt.yaml
│   └── show     Print the resolved config (with defaults filled in)
├── backends
│   ├── list     List configured backends and their status
│   └── ping     Test connectivity to each backend
├── status       Live health dashboard (interactive TUI)
└── version      Print version info
```

### 2.4 `run` — The Primary Command

`shunt run` is the main use case. It starts the proxy server.

```
$ shunt run [OPTIONS]

OPTIONS:
    -c, --config <PATH>       Path to config file [default: shunt.yaml]
    -p, --port <PORT>         Listen port [default: 8080]
    -h, --host <HOST>         Listen address [default: 127.0.0.1]
    --log-level <LEVEL>       Log verbosity: error, warn, info, debug, trace [default: info]
    --no-color                Disable colored output
    --dry-run                 Validate config and exit without starting
    -v, --verbose             Shorthand for --log-level debug

EXAMPLES:
    shunt run                          # Start with shunt.yaml in current directory
    shunt run -c /etc/shunt/prod.yaml  # Start with a specific config file
    shunt run -p 3000                  # Override the listen port
    shunt run --dry-run                # Validate config without starting
```

**Default subcommand behavior**: `shunt` with no subcommand is equivalent to `shunt run`. This means `shunt -p 3000` works identically to `shunt run -p 3000`.

### 2.5 `config` — Configuration Management

```
$ shunt config check [OPTIONS]

OPTIONS:
    -c, --config <PATH>       Path to config file [default: shunt.yaml]

    Validates the config file and prints a diagnostic report.
    Exit code 0 if valid, 1 if errors found.

$ shunt config init [OPTIONS]

OPTIONS:
    -o, --output <PATH>       Output path [default: shunt.yaml]
    --single                  Generate a single-backend config
    --multi                   Generate a multi-backend config with 3 backends

$ shunt config show [OPTIONS]

OPTIONS:
    -c, --config <PATH>       Path to config file [default: shunt.yaml]

    Prints the fully resolved config with all defaults filled in.
    Useful for debugging "why is shunt doing X?" questions.
```

### 2.6 `backends` — Backend Connectivity

```
$ shunt backends list [OPTIONS]

OPTIONS:
    -c, --config <PATH>       Path to config file [default: shunt.yaml]
    --format <FORMAT>         Output format: table, json [default: table]

$ shunt backends ping [OPTIONS]

OPTIONS:
    -c, --config <PATH>       Path to config file [default: shunt.yaml]
    --timeout <MS>            Per-backend timeout in milliseconds [default: 5000]

    Sends a lightweight request to each backend and reports
    reachability, latency, and model availability.
```

### 2.7 `status` — Live Health Dashboard

```
$ shunt status [OPTIONS]

OPTIONS:
    -c, --config <PATH>       Path to config file [default: shunt.yaml]
    --refresh <MS>            Refresh interval in milliseconds [default: 1000]
    --no-tui                  Print status once and exit (non-interactive)

    Opens an interactive terminal UI showing:
    - Backend health (online/degraded/offline per node)
    - Request rate (req/s per backend)
    - Cache hit rate (rolling percentage)
    - Latency percentiles (p50, p90, p99)
    - Recent request log (last 20 requests)

    Press q or Ctrl+C to exit.
```

### 2.8 `version` — Build Information

```
$ shunt version

shunt 0.1.0
zig 0.13.0
build: a1b2c3d (2026-04-22)
license: AGPL-3.0
```

Also accessible via `shunt --version` or `shunt -V`.

---

## 3. Help Text Style

### 3.1 Formatting Rules

- **Usage line**: indented 2 spaces, `<REQUIRED>` in angle brackets, `[OPTIONAL]` in square brackets
- **Options**: aligned at column 24, short flag first then long flag, separated by `, `
- **Descriptions**: sentence case, no period at end, max 72 chars
- **Examples section**: always present for `run` and `config init`, prefixed with `EXAMPLES:`
- **Defaults**: shown in `[default: X]` brackets at end of description
- **No ASCII art, no emoji** — plain text only

### 3.2 Help Text Template

```
shunt <SUBCOMMAND>

SUBCOMMANDS:
    run        Start the load balancer proxy
    config     Validate, generate, or print configuration
    backends   List and test backend connectivity
    status     Show live health and routing status
    version    Print version and build info

OPTIONS:
    -h, --help             Print help
    -V, --version          Print version

Run `shunt <subcommand> --help` for more information on a subcommand.
```

### 3.3 Error-Help Integration

When a user provides invalid flags or missing arguments, print the specific error first, then a short usage hint — not the full help text.

```
error: required argument `--port` expects a number, got `abc`

  tip: --port accepts an integer between 1 and 65535

Usage: shunt run [OPTIONS]

Run `shunt run --help` for full usage information.
```

---

## 4. Config File UX

### 4.1 Config File Format: YAML

YAML is the only supported format. Reasons:
- Most familiar to DevOps/infra engineers (Kubernetes, Docker Compose, GitHub Actions)
- Comments supported natively (unlike JSON)
- Readable and diff-friendly (unlike TOML for nested structures)

File name: `shunt.yaml` (default). Also accepts `shunt.yml`.

### 4.2 Minimal Config (Zero-Config Mode)

If no `shunt.yaml` exists, `shunt run` starts in **zero-config mode**:

```yaml
# No file needed. shunt will:
#   - Listen on 127.0.0.1:8080
#   - Proxy to a single backend at OPENAI_API_BASE_URL (env var)
#   - Use the API key from OPENAI_API_KEY (env var)
#   - Route all requests to that single backend
#   - Log at info level
```

If neither `shunt.yaml` nor `OPENAI_API_BASE_URL` is set, print an actionable error:

```
error: no backends configured

  tip: Create a config file with `shunt config init --single`
       or set OPENAI_API_BASE_URL and OPENAI_API_KEY environment variables.

  shunt requires at least one backend to route requests to.
```

### 4.3 Single-Backend Config

```yaml
# shunt.yaml — single backend
backend:
  url: https://api.openai.com
  api_key: ${OPENAI_API_KEY}
  model: gpt-4o

listen:
  port: 8080
  host: 127.0.0.1
```

### 4.4 Multi-Backend Config

```yaml
# shunt.yaml — multi-backend with routing
backends:
  - id: primary
    url: https://api.openai.com
    api_key: ${OPENAI_API_KEY}
    model: gpt-4o
    weight: 3

  - id: fallback
    url: https://api.anthropic.com
    api_key: ${ANTHROPIC_API_KEY}
    model: claude-sonnet-4-20250514
    weight: 1

  - id: local
    url: http://localhost:11434
    model: llama3
    weight: 2

routing:
  strategy: kv_cache_aware
  health_check_interval: 10s
  max_retries: 3
  retry_on: [timeout, server_error]

listen:
  port: 8080
  host: 127.0.0.1

logging:
  level: info
  format: text
```

### 4.5 Full Schema Reference

| Field | Type | Default | Required | Description |
|-------|------|---------|----------|-------------|
| `backend` | object | — | no* | Single backend (mutually exclusive with `backends`) |
| `backends` | array | — | no* | Multiple backends (mutually exclusive with `backend`) |
| `backends[].id` | string | auto-generated | no | Backend identifier for logs and status |
| `backends[].url` | string | — | yes | Backend API base URL |
| `backends[].api_key` | string | — | no | API key (supports `${ENV_VAR}` interpolation) |
| `backends[].model` | string | — | yes | Default model for this backend |
| `backends[].weight` | integer | 1 | no | Routing weight (higher = more requests) |
| `backends[].timeout` | duration | 30s | no | Request timeout |
| `backends[].max_connections` | integer | 100 | no | Connection pool limit |
| `routing.strategy` | string | round_robin | no | `round_robin`, `least_connections`, `kv_cache_aware` |
| `routing.health_check_interval` | duration | 10s | no | How often to check backend health |
| `routing.max_retries` | integer | 3 | no | Max retry attempts on failure |
| `routing.retry_on` | array | [timeout, server_error] | no | Which error types trigger a retry |
| `listen.port` | integer | 8080 | no | Proxy listen port |
| `listen.host` | string | 127.0.0.1 | no | Proxy listen address |
| `logging.level` | string | info | no | `error`, `warn`, `info`, `debug`, `trace` |
| `logging.format` | string | text | no | `text`, `json` |

*One of `backend` or `backends` is required unless environment variable fallback applies.

### 4.6 Environment Variable Interpolation

Config values supports `${ENV_VAR}` syntax. This is the only way to inject secrets.

```yaml
api_key: ${OPENAI_API_KEY}
url: ${LLM_ENDPOINT:-https://api.openai.com}
```

- `${VAR}` — required, error if unset
- `${VAR:-default}` — use default if unset
- `${VAR:+override}` — use override if set (advanced)

Interpolation errors are caught at startup with actionable messages:

```
error: environment variable OPENAI_API_KEY is not set

  tip: Set it before running shunt:
       export OPENAI_API_KEY=sk-...
       shunt run

  Or add it to a .env file in the same directory as shunt.yaml.
  shunt does not read .env files automatically — use a process
  manager like direnv or envchain, or source the file manually.
```

### 4.7 Config Validation

`shunt config check` validates the config and prints a structured report:

```
$ shunt config check

  checking shunt.yaml ...

  ✓ syntax: valid YAML
  ✓ schema: all required fields present
  ✓ backends: 3 backends configured
  ✓ interpolation: all environment variables set
  ⚠ backends[1].weight: weight of 0 will receive no traffic
  ✗ backends[2].url: invalid URL — must include scheme (https:// or http://)

  1 error, 1 warning found.
  Run `shunt config check --verbose` for more details.
```

Exit codes:
- `0` — valid config, no warnings
- `0` — valid config with warnings (still runnable)
- `1` — invalid config, at least one error

### 4.8 Config Init

`shunt config init` generates a starter config:

```
$ shunt config init --multi

  Created shunt.yaml with 3 backend entries.

  Edit the file to add your API keys and model names:
    backends[0].api_key → ${OPENAI_API_KEY}
    backends[1].api_key → ${ANTHROPIC_API_KEY}
    backends[2].url → your local model URL

  Then validate with: shunt config check
  And start with:     shunt run
```

The generated file includes inline comments explaining every field.

---

## 5. Terminal Output UX

### 5.1 Startup Banner

When `shunt run` starts, it prints a concise banner and is ready:

```
$ shunt run

  shunt 0.1.0
  listening on 127.0.0.1:8080
  backends: 3 (2 healthy, 1 degraded)
  routing: kv_cache_aware

  → ready
```

Design rules for the banner:
- Maximum 6 lines
- Version on first line
- Listen address on second line
- Backend summary on third line (count + health)
- Routing strategy on fourth line
- `→ ready` on the last line in crimson (the `→`) and snow white (`ready`)
- No ASCII art, no logo, no box drawing
- Suppressed with `--log-level error` or `--quiet` (if added)

### 5.2 Request Logging

#### Standard (info) Level

Each proxied request logs a single line:

```
→ POST /v1/chat/completions → primary 47ms 200 [cache: hit 94%]
→ POST /v1/chat/completions → fallback 312ms 200 [cache: miss]
→ POST /v1/chat/completions → primary 62ms 200 [cache: partial 31%]
```

Format:
```
→ <METHOD> <PATH> → <BACKEND_ID> <LATENCY>ms <STATUS> [cache: <HIT_TYPE> <PERCENT>%]
```

- `→` in crimson
- Method and path in snow white
- Backend ID in silver
- Latency in gold if below p50, silver if between p50-p99, crimson if above p99 or timeout
- Status code: green for 2xx, gold for 4xx, crimson for 5xx
- Cache: `hit` in gold, `miss` in crimson, `partial` in silver

#### Debug Level

Adds request headers, model name, token counts:

```
→ POST /v1/chat/completions → primary 47ms 200 [cache: hit 94%]
  model: gpt-4o  tokens: 1247+89  backend_latency: 41ms
```

#### Trace Level

Adds full request/response metadata (no body, for privacy):

```
→ POST /v1/chat/completions → primary 47ms 200 [cache: hit 94%]
  model: gpt-4o  tokens: 1247+89  backend_latency: 41ms
  x-request-id: req_abc123  x-ratelimit-remaining: 4992
```

#### JSON Format

When `logging.format: json` is set, each line is a JSON object:

```json
{"ts":"2026-04-22T12:00:00Z","method":"POST","path":"/v1/chat/completions","backend":"primary","latency_ms":47,"status":200,"cache":"hit","cache_pct":94}
```

JSON logging always includes all fields regardless of log level. Level filtering still applies — `info` omits debug/trace fields but the JSON structure is the same.

### 5.3 Health Status Output

#### `shunt backends list` — Table Format

```
ID        URL                            STATUS     LATENCY   MODEL         WEIGHT
primary   https://api.openai.com         healthy    41ms      gpt-4o        3
fallback  https://api.anthropic.com      healthy    89ms      claude-sonnet 1
local     http://localhost:11434         degraded   203ms     llama3        2
offline   http://10.0.0.50:8080         offline    —         mistral       1
```

- Status colors: `healthy` = green, `degraded` = gold, `offline` = crimson
- Latency: gold for fast (< 100ms), silver for medium, crimson for slow (> 500ms)
- `—` for unreachable backends

#### `shunt backends ping` — Connectivity Test

```
pinging 3 backends ...

  primary     ✓ reachable   41ms  /v1/models returned 46 models
  fallback    ✓ reachable   89ms  /v1/models returned 12 models
  local       ⚠ degraded    203ms /v1/models returned 1 model (high latency)
  offline     ✗ unreachable  —     connection refused after 5000ms

  2 healthy, 1 degraded, 1 unreachable
```

### 5.4 Error Formatting

All errors follow a three-part structure:

```
error: <what went wrong>

  tip: <what to do about it>

  <optional additional context>
```

#### Startup Errors

```
error: config file not found: /etc/shunt/prod.yaml

  tip: Create the file with `shunt config init -o /etc/shunt/prod.yaml`
       or check the path you passed with --config.

error: port 8080 is already in use by process 48291

  tip: Stop the other process, or choose a different port:
       shunt run --port 8081

error: no healthy backends available

  tip: All 3 configured backends are unreachable.
       Run `shunt backends ping` to diagnose connectivity.
       Check your API keys and network access.
```

#### Runtime Errors

```
error: backend "primary" returned 429 Too Many Requests

  tip: Rate limit exceeded. shunt will retry on other backends.
       If this persists, reduce request volume or add more backends.

error: all backends failed for POST /v1/chat/completions

  backends tried: primary (429), fallback (timeout 30s), local (connection refused)
  shunt will return 502 to the client.
```

#### Config Validation Errors

```
error: shunt.yaml: field `backends[2].url` is invalid

  14 |     url: api.openai.com
     |         ^^^^^^^^^^^^^^^
  expected: URL with scheme (https:// or http://)
  found:    bare hostname without scheme

  tip: Change to url: https://api.openai.com

error: shunt.yaml: field `routing.strategy` has unknown value

  22 |   strategy: cache_aware
     |            ^^^^^^^^^^^
  expected: one of round_robin, least_connections, kv_cache_aware
  found:    "cache_aware"

  tip: Did you mean kv_cache_aware?
```

### 5.5 Warning Formatting

Warnings use the same structure but with `warn:` prefix:

```
warn: backends[1].weight is 0 — this backend will receive no traffic

  tip: Set weight to 1 or higher, or remove the backend if unused.

warn: no API key configured for backend "local"

  tip: The backend will forward requests without authentication.
       This is expected for local models. If this backend requires
       an API key, add `api_key: ${LOCAL_API_KEY}` to its config.
```

---

## 6. Interactive Status TUI

### 6.1 Layout

`shunt status` opens a full-screen terminal UI that refreshes every second:

```
┌─ shunt status ──────────────────────────────────────────────┐
│                                                              │
│  BACKENDS (3)                                                │
│  ● primary    healthy   41ms   234 req/s   cache 94%        │
│  ● fallback   healthy   89ms    78 req/s   cache 61%        │
│  ◐ local      degraded 203ms    31 req/s   cache 12%        │
│                                                              │
│  THROUGHPUT                                                   │
│  343 req/s  |  12.4k req/min  |  89.2k today                │
│                                                              │
│  LATENCY                                                      │
│  p50: 47ms  p90: 89ms  p99: 203ms  cold: 312ms             │
│  ▁▂▃▅▇█▇▅▃▂▁▁▁▂▃▃▂▁▁▁▁▂▃▃▃▂▂▁▁  (60s sparkline)           │
│                                                              │
│  CACHE                                                        │
│  hits: 94.2%  misses: 5.8%  est. savings: $2,847/mo        │
│                                                              │
│  RECENT REQUESTS                                              │
│  → POST /v1/chat/completions → primary   47ms  200 [hit]    │
│  → POST /v1/chat/completions → primary   62ms  200 [hit]    │
│  → POST /v1/chat/completions → fallback 312ms  200 [miss]   │
│  → POST /v1/chat/completions → primary   43ms  200 [hit]    │
│                                                              │
│  q: quit  ↑↓: scroll requests  r: refresh now               │
└──────────────────────────────────────────────────────────────┘
```

### 6.2 TUI Design Rules

- Uses the full terminal size (respects SIGWINCH)
- Updates every 1s by default (configurable with `--refresh`)
- No mouse required — keyboard only
- Graceful degradation on small terminals (min 80x24)
- Colors follow the brand color map (Section 3.2 of brand style guide)
- `--no-color` flag disables all ANSI color codes
- `--no-tui` prints the status once in plain text and exits

### 6.3 Non-Interactive Output (`--no-tui`)

```
$ shunt status --no-tui

  backends:
    primary    healthy   41ms   234 req/s   cache 94%
    fallback   healthy   89ms    78 req/s   cache 61%
    local      degraded 203ms    31 req/s   cache 12%

  throughput:  343 req/s  (12.4k req/min, 89.2k today)
  latency:     p50 47ms  p90 89ms  p99 203ms  cold 312ms
  cache:       94.2% hits  5.8% misses  est. savings $2,847/mo
```

Machine-readable alternative:

```
$ shunt status --no-tui --format json
```

Returns a JSON object with all status fields. Intended for monitoring integrations and scripts.

---

## 7. Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Successful execution (including `config check` with warnings) |
| 1 | General error (invalid args, config errors, startup failure) |
| 2 | Misuse of shell command (wrong subcommand, missing required arg) |
| 130 | Interrupted (Ctrl+C) — clean shutdown |

Specific exit code guidance:
- `shunt run`: exits 0 on graceful shutdown (SIGTERM/SIGINT), 1 on fatal error
- `shunt config check`: exits 0 if valid (even with warnings), 1 if any errors
- `shunt backends ping`: exits 0 if all backends reachable, 1 if any unreachable

---

## 8. Signal Handling

| Signal | Behavior |
|--------|----------|
| SIGINT | Graceful shutdown: stop accepting new requests, finish in-flight requests, exit 0 |
| SIGTERM | Same as SIGINT |
| SIGHUP | Reload config file without restarting (if supported) |

On graceful shutdown, shunt prints:

```
  shutting down ...
  waiting for 4 in-flight requests to complete

  → done (3 requests completed, 1 timed out after 10s)
```

---

## 9. Color Specification

### 9.1 When to Use Color

- Color is ON by default when output is a terminal (isatty check)
- Color is OFF by default when output is piped or redirected
- `--no-color` flag forces color off
- `FORCE_COLOR=1` environment variable forces color on (for wrappers like `less -R`)
- `NO_COLOR=1` environment variable forces color off (respects the no-color.org convention)

### 9.2 Color Map for CLI

| Element | Foreground | ANSI | Use |
|---------|-----------|------|-----|
| `→` route arrow | Crimson | 38;5;160 | Routing indicators |
| Error text | Crimson | 38;5;160 | `error:` prefix and messages |
| Warning text | Gold | 38;5;220 | `warn:` prefix and messages |
| Success / healthy | Green | 38;5;34 | `✓`, `healthy` status |
| Degraded / partial | Gold | 38;5;220 | `⚠`, `degraded` status |
| Offline / fail | Crimson | 38;5;160 | `✗`, `offline` status |
| Cache hit % | Gold | 38;5;220 | Cache percentage values |
| Latency (fast) | Gold | 38;5;220 | < p50 latency values |
| Latency (medium) | Silver | 38;5;250 | p50–p99 latency values |
| Latency (slow) | Crimson | 38;5;160 | > p99 latency values |
| Status code (2xx) | Green | 38;5;34 | HTTP 200–299 |
| Status code (4xx) | Gold | 38;5;220 | HTTP 400–499 |
| Status code (5xx) | Crimson | 38;5;160 | HTTP 500+ |
| Primary text | Snow White | 39 | Paths, IDs, values |
| Secondary text | Silver | 38;5;250 | Labels, timestamps |
| Dim text | Cloud | 38;5;245 | Config comments, context lines |

### 9.3 Text Formatting

| Style | ANSI | Use |
|-------|------|-----|
| Bold | 1 | `error:`, `warn:`, `tip:` prefixes |
| Underline | 4 | File paths in error messages (when terminal supports it) |
| Normal | 0 | All other text |

---

## 10. Accessibility in the Terminal

- All color-dependent information has a text alternative: `✓` / `⚠` / `✗` symbols always accompany color
- The `--no-color` flag and `NO_COLOR` env var are documented in `--help`
- JSON output format includes all data without color dependency
- Sparklines in TUI degrade to numeric values when color is off
- Tabular output uses spacing alignment, not color alone, to distinguish columns

---

## 11. Config Init — Generated File Template

`shunt config init --multi` generates this file:

```yaml
# shunt.yaml — generated by shunt config init
# Docs: https://shunt.sh/docs/config
# License: AGPL-3.0

# Backends: the LLM endpoints shunt routes between.
# Each backend needs a URL and a model at minimum.
backends:
  - id: openai
    url: https://api.openai.com
    api_key: ${OPENAI_API_KEY}
    model: gpt-4o
    weight: 3                # Higher weight = more traffic
    timeout: 30s             # Request timeout
    max_connections: 100     # Connection pool size

  - id: anthropic
    url: https://api.anthropic.com
    api_key: ${ANTHROPIC_API_KEY}
    model: claude-sonnet-4-20250514
    weight: 1

  - id: local
    url: http://localhost:11434
    model: llama3
    weight: 2

# Routing: how shunt decides which backend to use.
routing:
  strategy: kv_cache_aware   # round_robin | least_connections | kv_cache_aware
  health_check_interval: 10s
  max_retries: 3
  retry_on:                  # Which errors trigger a retry on another backend
    - timeout
    - server_error

# Listen: where the shunt proxy accepts connections.
listen:
  port: 8080
  host: 127.0.0.1

# Logging: what shunt prints to stderr.
logging:
  level: info                # error | warn | info | debug | trace
  format: text               # text | json
```

---

## 12. Interaction Patterns

### 12.1 First-Time User Flow

```
$ shunt run

error: no backends configured

  tip: Create a config file with `shunt config init --single`
       or set OPENAI_API_BASE_URL and OPENAI_API_KEY environment variables.

$ shunt config init --single

  Created shunt.yaml with 1 backend entry.

  Edit the file to add your API key:
    backend.api_key → ${OPENAI_API_KEY}

  Then start with: shunt run

$ export OPENAI_API_KEY=sk-...
$ shunt run

  shunt 0.1.0
  listening on 127.0.0.1:8080
  backends: 1 (1 healthy)
  routing: round_robin

  → ready
```

### 12.2 Debugging a Misconfigured Backend

```
$ shunt run

error: backend "primary" is unreachable: connection refused

  tip: Run `shunt backends ping` to test connectivity.
       Check that the URL is correct and the service is running.

$ shunt backends ping

pinging 1 backend ...

  primary  ✗ unreachable  —  connection refused after 5000ms

  0 healthy, 1 unreachable

$ shunt config show

  backends:
    - id: primary
      url: https://api.openai.comm    # ← typo: .comm instead of .com
      ...

  tip: Check the URL for backend "primary".
```

### 12.3 Adding a Backend

```
$ shunt config init --multi -o /tmp/new-config.yaml

  Created /tmp/new-config.yaml with 3 backend entries.

  Edit the file, then validate:
    shunt config check -c /tmp/new-config.yaml

$ shunt config check -c /tmp/new-config.yaml

  checking /tmp/new-config.yaml ...

  ✓ syntax: valid YAML
  ✓ schema: all required fields present
  ✓ backends: 3 backends configured
  ⚠ interpolation: OPENAI_API_KEY is not set (will fail at runtime without it)
  ⚠ interpolation: ANTHROPIC_API_KEY is not set

  0 errors, 2 warnings found.
```

---

## 13. Edge Cases and Design Decisions

| Scenario | Decision | Rationale |
|----------|----------|-----------|
| No config file, no env vars | Error with `config init` suggestion | Don't guess — tell the user what to do |
| Config file with both `backend` and `backends` | Error: "use `backend` for single or `backends` for multiple, not both" | Prevent ambiguity |
| Unknown routing strategy | Error with "did you mean?" suggestion | Typo-friendly |
| API key in config file (not env var) | Warning: "api_key should use ${ENV_VAR} interpolation. Plain-text keys may be visible in logs and version control." | Security nudge without blocking |
| Backend returns non-JSON | Error with raw status code and hint | Don't crash on unexpected responses |
| SIGINT during startup | Exit immediately without "waiting for requests" message | No requests in flight yet |
| `shunt run` with `--dry-run` | Validate config, print banner, exit 0 | CI/CD pipeline validation |
| Multiple config files in directory | Only `shunt.yaml` or `shunt.yml` is auto-detected. Others require `--config` | No ambiguity |

---

## 14. Output Destination Rules

| Stream | Content |
|--------|---------|
| stdout | Machine-readable output: `version` output, `config show` output, JSON format data |
| stderr | Human-readable output: banner, request logs, errors, warnings, TUI |
| stdin | Not used (no interactive prompts — all input via flags and config) |

This allows piping stdout for scripting while keeping human-readable output on stderr:

```bash
shunt version | awk '{print $2}'    # extracts "0.1.0"
shunt run 2>shunt.log              # logs to file, stdout stays clean
```

---

## 15. Version Compatibility Notes

- The CLI interface follows semantic versioning: major versions may break the command structure
- Config file schema follows the same semver contract
- The `shunt.yaml` format will include a `version` field starting at `1` in v1.0.0 — before that, the schema may change between minor versions with migration guidance
- All deprecated flags/subcommands print a warning for one major version before removal

---

## 16. Summary of Key UX Decisions

1. **`shunt` with no args starts the proxy** — not help, not an error. The happy path is zero friction.
2. **Zero-config for single backend** — env vars + no file = working proxy.
3. **Errors are conversations** — every error has a `tip:` with a concrete next action.
4. **Color is structural, not decorative** — color carries meaning (health, latency tier, cache status). Text alternatives always exist.
5. **One line per request** — no multi-line log spam. Debug/trace levels add detail below the main line.
6. **Config init generates working examples** — never a blank template. Always a file the user can edit and run.
7. **JSON output for machines, text for humans** — `--format json` on every command that produces data.
8. **Graceful shutdown is the default** — SIGINT and SIGTERM finish in-flight work.
9. **Brand consistency** — crimson arrows, gold cache metrics, green health, silver structure. Same color language as the dashboard and landing page.
