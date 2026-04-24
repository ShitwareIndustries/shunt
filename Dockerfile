# SPDX-License-Identifier: AGPL-3.0-only
# Shunt — LLM proxy with KV-cache reuse routing
# Multi-stage Dockerfile: build with Zig SDK, run from alpine for healthcheck

# =============================================================================
# Stage 1: Build
# Uses the official Zig image to compile a static ReleaseSafe binary.
# =============================================================================
FROM ziglang/zig:0.16.0 AS builder

WORKDIR /app

COPY build.zig build.zig.zon ./
COPY src/ src/

RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

# =============================================================================
# Stage 2: Runtime
# Uses alpine for minimal footprint with HEALTHCHECK support (wget).
# - Non-root user for security
# - HEALTHCHECK hitting /health every 30s
# - Config via mount (/etc/shunt/config.toml) or env vars
# =============================================================================
FROM alpine:3.21

RUN adduser -D -s /sbin/nologin shunt

COPY --from=builder /app/zig-out/bin/shunt /usr/local/bin/shunt

USER shunt

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:8080/health || exit 1

ENTRYPOINT ["/usr/local/bin/shunt"]
