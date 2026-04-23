# X/Twitter Launch Thread — shunt

Post these 6 tweets in sequence. GitHub link goes in a reply to tweet 1, NOT in the tweet body.

---

**Tweet 1 (Lead):**

shunt: an LLM load balancer that routes by KV cache, not just connections. Open source. Zig-native. Drop-in OpenAI API replacement.

**Reply to tweet 1 (GitHub link):**

github.com/ShitwareIndustries/shunt

---

**Tweet 2 (Problem):**

Most LLM load balancers ignore your KV cache. They route round-robin. That means every request recomputes tokens you already processed. Wasted GPU time. Wasted money.

---

**Tweet 3 (Solution):**

shunt hashes the prompt prefix, finds the backend that already has it cached, and routes there. Cache hit = skip 90%+ of prefill compute. No cache match? Falls back to least-connections.

---

**Tweet 4 (Demo):**

```
$ ./shunt --config=config.toml
info: shunt starting on 0.0.0.0:8080
info: backend 'primary' at http://127.0.0.1:8081
info: backend 'secondary' at http://127.0.0.1:8082
info: routing strategy: kv-cache-affinity
info: ready
```

---

**Tweet 5 (Quick start):**

3 commands. 30 seconds to load-balanced LLMs.

```
curl -LO https://github.com/ShitwareIndustries/shunt/releases/latest/download/shunt-linux-x86_64
chmod +x shunt-linux-x86_64
./shunt-linux-x86_64 --config=config.toml
```

---

**Tweet 6 (CTA):**

Star us on GitHub. Try it. Tell us what breaks. AGPL v3 — read the code, fork it, ship it.
