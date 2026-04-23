# SPDX-License-Identifier: AGPL-3.0-only
# Shunt — LLM proxy with KV-cache reuse routing
# Multi-stage Dockerfile: build with Zig SDK, run from scratch

# =============================================================================
# Stage 1: Build
# Uses the official Zig image to compile a static ReleaseSafe binary.
# =============================================================================
FROM ziglang/zig:0.16.0 AS builder

WORKDIR /app

# Copy dependency manifests first for better Docker layer caching.
COPY build.zig build.zig.zon ./
COPY src/ src/

RUN zig build -Doptimize=ReleaseSafe

# =============================================================================
# Stage 2: Runtime
# Uses scratch for the smallest possible image with zero OS attack surface.
#
# Tradeoff: scratch has no shell, no wget, no curl — Docker HEALTHCHECK
# cannot run inside the container. We handle health checking two ways:
#   1. Caddy reverse proxy probes /healthz upstream (see Caddyfile).
#   2. docker-compose.yml uses an external healthcheck (disabled on the
#      container itself; compose healthcheck would need a tool like wget
#      which is absent in scratch).
#
# If Docker-level HEALTHCHECK is required, switch the runtime image to
# alpine:3.21 and add `wget` or `curl`. The scratch approach is preferred
# for production because it eliminates an entire OS from the attack surface.
# =============================================================================
FROM scratch

COPY --from=builder /app/zig-out/bin/shunt /shunt

EXPOSE 8080

ENTRYPOINT ["/shunt"]
