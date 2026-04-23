# Why We Built shunt in Zig

Most LLM infrastructure is written in Python or Go. We wrote shunt in Zig. This is not a Zig advocacy piece — it is an explanation of why this specific project needed this specific tool. If you are evaluating languages for a network proxy with hard latency requirements and explicit memory management needs, this might save you some time.

## The problem

shunt is an LLM load balancer. It sits between your application and multiple llama.cpp backends, routing OpenAI-compatible API requests to the instance with the best KV-cache hit rate. Every millisecond it adds to the request path is a millisecond added to your LLM response time.

A load balancer that introduces latency is a failed load balancer. The language choice had to deliver predictable, low-latency performance under sustained load. No spikes. No pauses. No surprises.

## What we needed

The requirements were specific:

1. **Sub-millisecond proxy overhead** — the load balancer must add negligible latency to each request
2. **Explicit memory control** — KV-cache reuse routing requires tracking cache state across backends, and we need to manage that memory precisely
3. **Zero runtime dependencies** — self-hosted users should download a single binary and run it. No runtime. No package manager. No container required.
4. **Cross-compilation** — shunt users run on everything: x86 Linux, ARM macOS, Windows, bare metal VMs
5. **C interop** — llama.cpp is C. We need to talk to it without FFI overhead or wrapper layers

## What we evaluated

### Go

Go is the default for infrastructure tooling. Most LLM proxies (llama_swap, paddler) are in Go. The concurrency model is excellent for network services. The standard library is comprehensive. Hiring is easy.

But Go has a garbage collector. GC pauses are typically sub-millisecond, but "typically" is not "always." Under load — and a load balancer is always under load — GC pauses spike. A 10ms GC pause on a proxy handling 1000 req/s means 10 requests stall simultaneously. For an LLM proxy where every request already takes 100ms+ of inference time, adding unpredictable latency on top is unacceptable.

Go also hides allocations. `fmt.Sprintf` allocates. Slice append allocates. Interface boxing allocates. For a proxy that needs to track per-request cache state, hidden allocations mean hidden memory growth. You can work around this — sync.Pool, pre-allocated buffers, careful escape analysis — but you are fighting the language, not working with it.

### Rust

Rust was the other serious candidate. No GC. C-level performance. Excellent safety guarantees through the borrow checker. Growing ecosystem. Strong community.

The borrow checker is genuinely useful for preventing memory bugs. But for shunt's architecture — a network proxy with shared routing state, concurrent request handling, and cache affinity tracking — the ownership model adds complexity that does not pay for itself. The async runtime landscape (tokio, async-std) introduces choices that fragment the ecosystem. Cross-compilation works but requires more toolchain setup than we wanted.

Rust is a fine choice for many projects. For a network proxy where the concurrency model is straightforward (accept, route, forward, track), it was more language than the problem required.

### C

C is the baseline for systems programming. No GC. No runtime. Direct memory control. Maximum performance. C interop is trivial when your upstream (llama.cpp) is already C.

But C's safety story is poor. Buffer overflows, use-after-free, integer overflow — these are real bugs that real C projects ship. Writing safe C requires discipline that compilers do not enforce. We wanted the performance characteristics of C with better compile-time safety guarantees.

## Why Zig

Zig fits shunt's requirements specifically. Here is how.

### No hidden control flow

Zig has no hidden allocations, no implicit conversions, no operator overloading, no closures capturing by reference. What you read in the source is what happens at runtime. For a proxy where latency predictability matters, this is critical. You can reason about performance by reading the code, not by running a profiler.

```zig
fn route_request(cache_table: *CacheTable, prompt: []const u8) !BackendId {
    const prefix_hash = hash_prefix(prompt);
    const entry = cache_table.lookup(prefix_hash) orelse {
        return fallback_route();
    };
    return entry.backend_id;
}
```

No hidden allocation in `hash_prefix`. No boxing in `lookup`. No dynamic dispatch. The compiler generates exactly what you wrote.

### Comptime

Zig's comptime (compile-time code execution) eliminates runtime overhead for configuration and routing logic. We validate route rules, generate dispatch tables, and compute constants at compile time — not at startup, not on first request, at compile time.

```zig
fn RoutingTable(comptime backends: []const BackendConfig) type {
    return struct {
        entries: [backends.len]Entry,
        pub fn init() @This() {
            var table: @This() = undefined;
            comptime var i = 0;
            inline while (i < backends.len) : (i += 1) {
                table.entries[i] = Entry.from_config(backends[i]);
            }
            return table;
        }
    };
}
```

The routing table structure is generated at compile time based on the number of backends. No runtime allocation. No dynamic dispatch. The compiler knows the size of everything.

### Explicit allocator model

Every allocation in Zig takes an allocator as a parameter. This is not a global allocator you configure once and forget. Each data structure specifies its allocator explicitly. For shunt, this means:

- Request handling uses an arena allocator — allocate freely during request processing, free everything in one operation when the request completes
- Cache state tracking uses a page allocator — long-lived data with predictable growth
- No GC means no surprise memory spikes during cache operations

```zig
pub fn handle_request(arena: *std.mem.Allocator, req: *Request) !Response {
    // Allocate freely — all freed when arena resets
    const headers = try arena.create(Headers);
    const body = try arena.alloc(u8, req.content_length);
    // ... process request ...
    // No individual frees needed — arena resets after response
}
```

Arena allocation for request handling means zero fragmentation, zero individual free overhead, and predictable memory behavior under load.

### Cross-compilation

Zig's cross-compilation is first-class. Building for a new target is a command-line flag, not a toolchain installation:

```
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-gnu
```

No cross-compiler packages. No sysroot setup. No CMake toolchain files. For shunt's audience — self-hosted LLM operators running on whatever hardware they have — this matters. One command per platform.

### Zig cc

`zig cc` is a drop-in C compiler. It ships with libc headers for all supported targets. When we need to link against llama.cpp's C API, there is no separate toolchain to configure. Zig handles the C compilation and cross-compilation in the same step.

This is not a small thing. C interop in other languages requires FFI bindings, cgo overhead, or build system integration. With Zig, C headers are importable directly, and the build system handles the linking. The overhead is zero — Zig calls C at C speed.

### Single static binary

The output of `zig build` is a single static binary. No libc dependency (by default). No runtime. No shared libraries. No package manager. Download it, `chmod +x`, run it. This is the deployment model self-hosted users expect:

```
curl -LO https://github.com/ShitwareIndustries/shunt/releases/latest/download/shunt-linux-x86_64
chmod +x shunt-linux-x86_64
./shunt-linux-x86_64 --config=config.toml
```

Three commands. No Docker. No pip. No cargo install. No package manager fight.

## What we gave up

Zig is not perfect. The trade-offs are real:

**Ecosystem size.** Zig's package ecosystem is small compared to Go or Rust. There is no HTTP framework equivalent to Gin or Actix. We wrote our own HTTP server — which is fine for our needs, but not every team wants to do that.

**Hiring pool.** Far fewer developers know Zig than Go or Rust. If Shitware Industries grows, finding Zig programmers will be harder. Our bet: the kind of engineer who wants to work on LLM infrastructure in Zig is the kind of engineer we want to hire. Small pool, high average.

**Compile times.** Zig compiles slower than Go. Not catastrophically slow, but noticeably. Incremental builds help. Full debug builds on large projects take patience. Release builds are faster due to LLVM backend optimizations.

**Language maturity.** Zig has not reached 1.0. The standard library API changes between releases. We pin our Zig version and update deliberately. This is a cost we accepted.

**Async.** Zig's async implementation is stack-based and currently in flux. For shunt, we use an event loop with non-blocking I/O rather than Zig's built-in async. This works but is more manual than Go's goroutines or Rust's async/await.

## The result

shunt is a single binary, under 5MB, that proxies OpenAI-compatible API requests across llama.cpp instances with KV-cache reuse routing. It adds sub-millisecond overhead to each request. It uses no runtime. It cross-compiles to every platform our users care about. It links against llama.cpp's C API with zero FFI overhead.

The language choice served the project. That is the only claim we are making. Zig is not the right choice for every project — or even most projects. But for a network proxy that needs predictable latency, explicit memory control, and zero-dependency deployment, it was the right choice for this one.

## Try it

```bash
curl -LO https://github.com/ShitwareIndustries/shunt/releases/latest/download/shunt-linux-x86_64
chmod +x shunt-linux-x86_64
./shunt-linux-x86_64 --config=config.toml
```

shunt is AGPL v3. Read the code. Fork it. Fix it.

---

*Shitware Industries. Ship it. We dare you.*
