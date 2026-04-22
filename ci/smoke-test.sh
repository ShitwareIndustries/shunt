#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BIN="$PROJECT_ROOT/zig-out/bin/shunt"
HEALTH_URL="http://127.0.0.1:18080/health"
READY_URL="http://127.0.0.1:18080/health"
TIMEOUT=10
SHUNT_PID=""

cleanup() {
    if [ -n "$SHUNT_PID" ]; then
        kill "$SHUNT_PID" 2>/dev/null || true
        wait "$SHUNT_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ ! -x "$BIN" ]; then
    echo "ERROR: binary not found at $BIN" >&2
    echo "Run 'zig build' first" >&2
    exit 1
fi

"$BIN" --listen-addr=127.0.0.1:18080 &
SHUNT_PID=$!

elapsed=0
while [ $elapsed -lt $TIMEOUT ]; do
    if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
        echo "PASS: /health returned 200"
        if curl -sf "$READY_URL" >/dev/null 2>&1; then
            echo "PASS: /health readiness check returned 200"
            exit 0
        fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

echo "FAIL: server did not become healthy within ${TIMEOUT}s" >&2
exit 1
