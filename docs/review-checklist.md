# Shunt Code Review Checklist

License: AGPL v3

## How to Use

Every PR touching Zig code in `/root/shunt/` must be reviewed against this
checklist before merge. Mark each item [PASS], [FAIL], or [N/A]. Any FAIL is
blocking unless explicitly waived by CTO.

---

## 1. Build & Formatting

- [ ] `zig fmt --check` passes on all changed `.zig` files
- [ ] `zig build` compiles without errors
- [ ] `zig build test` passes all tests
- [ ] `build.zig` changes (if any) are correct and don't break existing steps
- [ ] No compiler warnings (Zig warnings are errors in practice)

## 2. Zig Code Style

- [ ] 4-space indentation (no tabs in `.zig` files)
- [ ] `const` preferred over `var` — variables are immutable unless mutability is required
- [ ] Snake_case for functions and variables; PascalCase for types
- [ ] No unused imports — every `const ... = @import(...)` is used
- [ ] No unused variables — `_ =` only for intentional discards where API requires it
- [ ] `@import("std")` aliased consistently as `const std = @import("std");`
- [ ] Error sets are explicit or inferred via `!T`; never bare `error` without type

## 3. Allocator Discipline

- [ ] Every allocation has a corresponding free (use `defer` for cleanup)
- [ ] No use of `std.heap.page_allocator` for general-purpose allocation — use arena or GPA
- [ ] Arena allocators used for request-scoped data; freed at end of request
- [ ] GeneralPurposeAllocator configured as root allocator in `main`
- [ ] No memory leaks in error paths — `errdefer` used where needed
- [ ] Allocator passed as parameter; no global allocator access (except `main` setup)
- [ ] Test allocations use `std.testing.allocator` — leaks caught by test runner

## 4. Error Handling

- [ ] Error unions used instead of null returns for fallible operations
- [ ] `catch` blocks don't silently swallow errors — at minimum, log the error
- [ ] `try` used for propagation; `catch` only when handling is meaningful
- [ ] `error` sets are specific (e.g., `NetworkError`, `ParseError`) not generic
- [ ] No `unreachable` except where truly impossible by construction
- [ ] HTTP error responses sent to client before returning error to caller

## 5. HTTP Protocol Compliance

- [ ] Request method validated (only GET, POST supported for OpenAI compat)
- [ ] Content-Length or Transfer-Encoding handled correctly
- [ ] Connection: close vs keep-alive respected per config
- [ ] Timeouts configured for both upstream and downstream connections
- [ ] Proper HTTP/1.1 status codes returned (not 200 for errors)
- [ ] Host header forwarded to upstream backends
- [ ] Request body fully consumed before sending response

## 6. SSE Streaming Correctness

- [ ] `data:` prefix on each SSE chunk
- [ ] Double newline (`\n\n`) terminates each SSE event
- [ ] `[DONE]` sentinel sent at end of stream
- [ ] Partial writes handled — loop until full buffer flushed
- [ ] Client disconnect detected during stream (EPIPE/ECONNRESET)
- [ ] Backend timeout during stream sends error to client, not hang
- [ ] No buffering of streaming responses — forward chunks immediately

## 7. Concurrency & Safety

- [ ] Shared state protected by Mutex where needed (backend pool, slot counters)
- [ ] No data races in test code (tests don't share mutable global state)
- [ ] Atomic operations used for counters updated across threads
- [ ] Thread shutdown signals respected (no infinite loops without exit condition)

## 8. Test Coverage

- [ ] Every public function has at least one test
- [ ] Error paths tested (invalid input, network failure, timeout)
- [ ] Edge cases covered: empty input, max-size input, malformed JSON
- [ ] SSE parsing tested with partial chunks and multi-event streams
- [ ] Backend pool tests cover: all-down, partial-down, slot tracking
- [ ] No test uses real network — mock or stub all HTTP calls
- [ ] `std.testing.allocator` used in all tests (not `page_allocator`)

## 9. Configuration & Build

- [ ] New config fields added to `config.zig` struct and TOML parsing
- [ ] `build.zig.zon` updated if new dependencies added
- [ ] `build.zig` test step covers all modules (no untested modules)
- [ ] No hardcoded paths or secrets in source code
- [ ] Config defaults are sensible and documented in `config.example.toml`

## 10. Security

- [ ] No logging of API keys, tokens, or request bodies containing secrets
- [ ] Input validation on all user-supplied data (model names, prompt content)
- [ ] No command injection vectors (no `std.process.exec` with user input)
- [ ] Rate limiting or request size limits enforced
- [ ] TLS used for upstream connections if backends are remote

---

## Review Annotations

| Marker | Meaning |
|--------|---------|
| BLOCKING | Must fix before merge |
| SUGGESTION | Recommended but not blocking |
| QUESTION | Needs clarification from author |
| N/A | Not applicable to this PR |

## Failure Modes to Consider When Reviewing

1. **Memory leak under load** — allocator not freed on error path
2. **SSE hang** — backend timeout not propagated to client during stream
3. **Race condition** — backend slot counter updated without lock
4. **Silent error swallow** — `catch {}` hides a network failure
5. **Partial write** — `writeAll` used where `writeAll` is correct but assumed complete
