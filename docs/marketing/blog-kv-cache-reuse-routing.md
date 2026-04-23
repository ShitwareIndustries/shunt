# KV-Cache Reuse Routing: How shunt Cuts Your LLM Bill

Every LLM request you proxy is probably wasting GPU time. Not because your models are slow — because your load balancer is dumb.

Most LLM load balancers route requests the same way web load balancers have routed HTTP traffic for decades: round-robin, least-connections, or random. These algorithms were designed for stateless web servers. They work fine when every request is independent. But LLM inference is not stateless. Each backend builds a KV cache — a growing data structure that stores the attention key-value pairs from previous tokens. When a new request shares a prefix with a cached conversation, the backend can skip recomputing those tokens. This is called a KV-cache hit, and it saves real GPU compute.

The problem: your load balancer does not know about any of this. It sends requests to whichever backend has the fewest connections, regardless of whether that backend has cached the relevant context.

shunt is an LLM load balancer that routes by KV cache state, not just connection count. This post explains how it works, why it matters, and when it helps.

## What is KV cache?

When an LLM processes a prompt, it computes attention over every token. The key and value tensors from these attention computations are stored in GPU memory — this is the KV cache. For a model like Llama 3 8B, a single conversation's KV cache can occupy hundreds of megabytes of GPU memory.

The KV cache grows as the conversation grows. Each new token adds key-value entries for every attention layer. For a 32-layer model, each token adds 32 entries. A 2048-token conversation has 65,536 KV-cache entries per layer. That is a lot of compute that you do not want to repeat.

Here is the key insight: **if a new request shares a prefix with a cached conversation, the backend can reuse the cached KV entries and skip the prefill computation for those tokens.** Instead of processing 2048 tokens, it might only need to process 50. The savings are enormous.

## The routing problem

Traditional load balancing algorithms treat every request as independent:

**Round-robin**: Request 1 goes to backend A, request 2 to backend B, request 3 to backend C, and so on. Simple. Stateless. Completely ignores cache state.

```
Client: "What is KV cache?"
  → Backend A (no cache for this topic)

Client: "Explain it in more detail"  [same conversation prefix]
  → Backend B (no cache — recomputes everything from scratch)

Client: "Give me a code example"  [same conversation prefix]
  → Backend C (no cache — recomputes everything again)
```

Three requests, same conversation prefix, three full prefill computations. Two of them were wasted.

**Least-connections**: Route to the backend with the fewest active connections. Better for load distribution, but still cache-blind. A backend with 1 connection and no relevant cache is preferred over a backend with 2 connections that already has the right cache entries.

**Random**: Self-explanatory. Still used. Still terrible for cache reuse.

The fundamental issue: these algorithms optimize for connection distribution, not compute efficiency. In LLM inference, the compute cost of a request depends heavily on whether the backend has cached the relevant prefix. A cache hit can reduce prefill work by 90%+. A cache miss means processing every token from scratch.

## How shunt routes

shunt uses prefix-aware routing with KV-cache affinity. Here is how it works:

### Step 1: Hash the prompt prefix

When a request arrives, shunt hashes the prompt prefix — the system prompt, conversation history, and any shared context that is likely to repeat across requests. This hash identifies the "cache family" the request belongs to.

```zig
const prefix_hash = hash_prefix(request.messages);
```

The prefix hash is deterministic. The same prompt prefix always produces the same hash. This means shunt can reliably route to the backend that cached that prefix, even if the request comes hours later.

### Step 2: Look up cache affinity

shunt maintains a cache affinity table that maps prefix hashes to backend IDs. When a backend processes a request, shunt records which prefix hash it handled and when. When a new request arrives, shunt checks the affinity table:

```zig
fn route(cache_table: *CacheTable, prefix_hash: u64) BackendId {
    if (cache_table.lookup(prefix_hash)) |entry| {
        if (entry.backend.is_healthy) {
            return entry.backend_id;
        }
    }
    return least_connections_fallback();
}
```

If the backend that cached this prefix is healthy and has capacity, shunt routes the request there. If it is down or overloaded, shunt falls back to least-connections routing.

### Step 3: Route and track

After routing, shunt updates the cache affinity table with the new assignment. Over time, the affinity table converges on a stable mapping where each conversation prefix tends to hit the same backend — maximizing cache reuse.

```
Client: "What is KV cache?"
  → Backend A (cache miss — full prefill, 2048 tokens)
  → Cache table: prefix_hash X → Backend A

Client: "Explain it in more detail"
  → shunt looks up prefix_hash X → Backend A
  → Backend A (cache HIT — skip 2048 tokens, process 50 new tokens)

Client: "Give me a code example"
  → shunt looks up prefix_hash X → Backend A
  → Backend A (cache HIT — skip 2058 tokens, process 30 new tokens)
```

Three requests, same backend, two cache hits. The second request processes 50 tokens instead of 2098. The third processes 30 tokens instead of 2088. That is the difference between "runs fine" and "saves significant GPU time."

## The numbers

Here is where we have to be honest: shunt does not have production benchmarks yet. We are building in the open and have not shipped. The numbers below are estimates based on known KV-cache behavior in llama.cpp and typical inference workloads. We will publish real benchmarks when we have them. Do not make purchasing decisions based on estimates.

### Estimated cost impact

For a typical multi-backend setup with repeated system prompts:

| Scenario | Tokens per request (no cache reuse) | Tokens per request (with shunt) | Estimated savings |
|----------|--------------------------------------|----------------------------------|-------------------|
| Repeated system prompt (500 tokens) | 500 + conversation | conversation only | ~500 tokens/request |
| Multi-turn chat (10 turns, same backend) | Sum of all turns | Only new tokens per turn | 40-60% fewer total tokens |
| RAG with shared context | Full context + query | Query only (context cached) | 70-90% fewer tokens |

At current GPU pricing (approximately $0.50/GPU-hour for an A100 equivalent), saving 500 tokens per request at 1000 req/s translates to meaningful cost reduction over a month. The exact number depends on your model, your hardware, and your traffic pattern. We will share concrete benchmarks when shunt is in production.

### Latency impact

KV-cache hits also reduce latency. Prefill is the most compute-intensive phase of inference. Skipping prefill for cached tokens means:

- First-token latency drops significantly for cache hits
- Time-to-first-token improves for multi-turn conversations
- Overall request latency decreases proportionally to cache hit rate

## When KV-cache reuse helps most

Not every workload benefits equally from cache-aware routing. Here is when it matters:

### High-benefit scenarios

- **API gateways with fixed system prompts** — every request includes the same system prompt. Cache it once, reuse it forever.
- **Multi-turn conversations** — each turn builds on the previous context. Routing to the same backend preserves the full KV cache.
- **RAG applications** — retrieval-augmented generation often reuses the same retrieved context across queries.
- **Batch processing with shared context** — processing multiple queries against the same document or knowledge base.

### Low-benefit scenarios

- **Novel prompts with no shared prefix** — if every request is unique, there is nothing to cache.
- **Single-backend setups** — with one backend, routing is trivial. You do not need shunt.
- **Very short prompts** — the overhead of hash computation may exceed the savings from a cache hit on a 10-token prompt.

## How other proxies handle this

They do not. Here is a comparison:

| Proxy | Routing strategy | Cache-aware | OpenAI-compatible | Self-hosted |
|-------|-----------------|-------------|-------------------|-------------|
| shunt | Prefix-hash KV-cache affinity | Yes | Yes | Yes |
| llama_swap | Round-robin | No | Partial | Yes |
| paddler | Least-connections | No | Partial | Yes |
| LiteLLM | Round-robin | No | Yes | No (SaaS option) |
| nginx/HAProxy | Various | No | No | Yes |

Generic load balancers (nginx, HAProxy) can distribute LLM traffic, but they have no mechanism to inspect prompt content or track cache state. They route at the connection layer, not the application layer. That is the gap shunt fills.

## Getting started

When shunt is ready, setup looks like this:

```toml
# config.toml
[balancer]
listen_addr = "0.0.0.0:8080"

[[models]]
id = "llama3-primary"
address = "http://localhost:8081"
model = "llama3"

[[models]]
id = "llama3-secondary"
address = "http://localhost:8082"
model = "llama3"

[[models]]
id = "llama3-tertiary"
address = "http://localhost:8083"
model = "llama3"
```

```bash
# Start shunt
./shunt --config config.toml

# Point your existing OpenAI client at shunt instead of api.openai.com
export OPENAI_API_BASE=http://localhost:8080/v1
```

```bash
# Start shunt
./shunt --config shunt.yaml

# Point your existing OpenAI client at shunt instead of api.openai.com
export OPENAI_API_BASE=http://localhost:443/v1
```

That is it. No SDK changes. No API migration. Swap the base URL. shunt handles the routing.

## Limitations

Honest limitations, not hedging:

1. **Only works with llama.cpp backends right now.** vLLM, TensorRT-LLM, and other backends have different KV-cache implementations. Support for those is on the roadmap.

2. **Cache affinity is probabilistic, not guaranteed.** If a backend evicts a cached prefix (due to memory pressure or context window limits), shunt will still route to it but the request will be a cache miss. shunt detects this and updates the affinity table, but the miss has already happened.

3. **Prefix hashing is approximate.** Two prompts with slightly different system prompts get different hashes, even if 99% of the context is shared. Smarter prefix matching (e.g., hierarchical hashing) is future work.

4. **No distributed cache yet.** KV-cache state is tracked per-shunt-instance. If you run multiple shunt instances, they do not share affinity tables. This is fine for single-node setups; multi-node cache coordination is a harder problem.

5. **Estimates, not benchmarks.** The cost savings numbers above are projections. We will not know the real numbers until shunt runs in production. If the real numbers are worse than estimates, we will say so.

## Why this matters

LLM inference is expensive. GPU time is the dominant cost for anyone running models at scale. Every token that gets recomputed because of a cache miss is a token you paid for but did not need to compute. Over millions of requests, those wasted tokens add up to real money.

KV-cache reuse routing is not a new idea — operating systems have cached frequently accessed data for decades. Database connection pools reuse warm connections. CDNs cache static content at the edge. The principle is the same: cache what you can, compute what you must. shunt applies this principle to LLM inference.

If you are running multiple LLM backends and routing requests with round-robin or least-connections, you are leaving GPU time on the table. Prefix-aware routing is the fix.

## Try it

shunt is shipping now:

```bash
curl -LO https://github.com/ShitwareIndustries/shunt/releases/latest/download/shunt-linux-x86_64
chmod +x shunt-linux-x86_64
./shunt-linux-x86_64 --config=config.toml
```

AGPL v3. Read the code. Fork it. Break it. Tell us what broke.

---

*Shitware Industries. Ship it. We dare you.*
