# shunt - Open-source LLM load balancer with KV-cache reuse routing (Zig, self-hosted, OpenAI-compatible)

I built an LLM load balancer that actually knows about your KV cache. It is called shunt.

If you run multiple llama.cpp instances, you know the deal: round-robin load balancing ignores your KV cache. Every new request recomputes tokens you already processed. That is wasted GPU time. Most proxies (llama_swap, paddler, nginx) route at the connection layer. They have no idea which backend already has your conversation cached.

shunt hashes the prompt prefix, finds the backend that already has it cached, and routes the request there. Cache hit = skip 90%+ of prefill compute. No cache match? Falls back to least-connections. Over time the affinity table converges so each conversation prefix tends to hit the same backend.

Yeah, the company name is Shitware Industries. The name is... a choice. The tool works though.

**Download and run in 30 seconds:**

```sh
curl -LO https://github.com/ShitwareIndustries/shunt/releases/latest/download/shunt-linux-x86_64
chmod +x shunt-linux-x86_64
```

Write a config file (TOML, 8 lines):

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

Point your OpenAI client at `http://localhost:8080`. No SDK changes. No API migration. Swap the base URL.

Make sure you have at least one LLM backend running on the configured ports before you start shunt.

**What works:**
- llama.cpp backends only right now
- KV-cache affinity routing with least-connections fallback
- Health checking, SSE streaming passthrough, request queuing
- OpenAI-compatible endpoints (/v1/chat/completions, /v1/models, /health)

**What does not:**
- Single-backend setups do not need this. You need at least 2 backends for routing to matter.
- vLLM, TensorRT-LLM, and other backends are not supported yet.
- No distributed cache coordination across multiple shunt instances.
- No production benchmarks yet. The cache reuse savings are estimates based on known KV-cache behavior in llama.cpp.

**What is next:**
Benchmark suite, vLLM backend support, multi-strategy routing, distributed cache coordination. AGPL v3 — read the code, fork it, ship it.

What would make this useful for your setup?

[github.com/ShitwareIndustries/shunt](https://github.com/ShitwareIndustries/shunt)
