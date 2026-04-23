# Show HN: shunt – An LLM load balancer that routes by KV cache, not just connections

shunt is a self-hosted LLM load balancer that routes requests by KV-cache state instead of round-robin. Built in Zig. Zero dependencies. AGPL v3.

Most LLM proxies (llama_swap, paddler, nginx) route round-robin or least-connections. They ignore KV cache. When a request shares a prefix with a cached conversation, the cache hit saves 90%+ of prefill compute. Your load balancer throws that away every time it sends a follow-up request to a different backend.

shunt hashes the prompt prefix, looks up which backend already has that prefix cached, and routes the request there. Cache hit means the backend skips recomputing cached tokens and only processes the new ones. No cache match? Falls back to least-connections. The affinity table converges over time — each conversation prefix tends to hit the same backend, maximizing reuse.

```sh
curl -LO https://github.com/ShitwareIndustries/shunt/releases/latest/download/shunt-linux-x86_64
chmod +x shunt-linux-x86_64
```

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

```sh
./shunt-linux-x86_64 --config=config.toml
```

Point your OpenAI client at `http://localhost:8080`. Done.

What is next: benchmark suite, multi-strategy routing (weighted round-robin, least-connections), vLLM backend support, distributed cache coordination across shunt instances.

What routing strategy does your LLM setup use? We would love to hear what works and what does not for multi-instance serving.

---

*Shitware Industries. Ship it. We dare you.*
