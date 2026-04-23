#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shunt — Passive node health monitoring script
#
# Periodically checks the primary shunt instance health endpoints.
# After 3 consecutive failures (3 minutes at 60s intervals),
# emits a failover alert. Can optionally trigger automatic rollback.
#
# Usage:
#   ci/health-monitor.sh              # monitor with alert only
#   ci/health-monitor.sh --auto-rollback  # monitor with automatic rollback
#
# Designed to run as a long-lived background process.
# Idempotent: safe to restart at any time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ACTIVE_COLOR_FILE="$PROJECT_ROOT/cfg/active-color"

CHECK_INTERVAL=60
FAILURE_THRESHOLD=3
ROLLBACK_SCRIPT="$SCRIPT_DIR/rollback.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    printf '{"time":"%s","level":"%s","msg":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

info()  { log "info"  "$@"; }
warn()  { log "warn"  "$@"; }
error() { log "error" "$@"; }

# ── Config ───────────────────────────────────────────────────────────────────

AUTO_ROLLBACK=false
for arg in "$@"; do
    case "$arg" in
        --auto-rollback)
            AUTO_ROLLBACK=true
            ;;
    esac
done

# ── Determine active color port ──────────────────────────────────────────────

get_active_port() {
    local color
    if [ -f "$ACTIVE_COLOR_FILE" ]; then
        color="$(cat "$ACTIVE_COLOR_FILE")"
    else
        color="blue"
    fi

    case "$color" in
        blue)  echo "8081" ;;
        green) echo "8082" ;;
        *)
            warn "Unknown active color '${color}', defaulting to blue"
            echo "8081"
            ;;
    esac
}

# ── Health check ─────────────────────────────────────────────────────────────

check_health() {
    local port="$1"
    local url="http://127.0.0.1:${port}/healthz"

    local http_code
    http_code="$(curl -sf -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"

    if [ "$http_code" = "200" ]; then
        echo "healthy"
    else
        echo "unhealthy"
    fi
}

check_readiness() {
    local port="$1"
    local url="http://127.0.0.1:${port}/readyz"

    local http_code
    http_code="$(curl -sf -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"

    if [ "$http_code" = "200" ]; then
        echo "ready"
    else
        echo "not_ready"
    fi
}

# ── Failover alert ───────────────────────────────────────────────────────────

trigger_failover() {
    local consecutive_failures="$1"
    error "Failover threshold reached: ${consecutive_failures} consecutive failures"

    if [ "$AUTO_ROLLBACK" = true ]; then
        warn "Auto-rollback enabled: triggering ci/rollback.sh"
        if [ -x "$ROLLBACK_SCRIPT" ]; then
            "$ROLLBACK_SCRIPT" || error "Auto-rollback failed"
        else
            error "Rollback script not found or not executable at $ROLLBACK_SCRIPT"
        fi
    else
        warn "Auto-rollback not enabled; manual intervention required"
        warn "Run: ci/rollback.sh"
    fi
}

# ── Main monitoring loop ────────────────────────────────────────────────────

main() {
    local consecutive_failures=0

    info "Health monitor started (interval=${CHECK_INTERVAL}s, threshold=${FAILURE_THRESHOLD}, auto-rollback=${AUTO_ROLLBACK})"

    while true; do
        local port
        port="$(get_active_port)"

        local health_status
        health_status="$(check_health "$port")"

        local readiness_status
        readiness_status="$(check_readiness "$port")"

        if [ "$health_status" = "healthy" ] && [ "$readiness_status" = "ready" ]; then
            info "Health OK (port=${port}, health=${health_status}, readiness=${readiness_status})"
            consecutive_failures=0
        else
            consecutive_failures=$((consecutive_failures + 1))
            warn "Health check failed (port=${port}, health=${health_status}, readiness=${readiness_status}, consecutive=${consecutive_failures}/${FAILURE_THRESHOLD})"

            if [ "$consecutive_failures" -ge "$FAILURE_THRESHOLD" ]; then
                trigger_failover "$consecutive_failures"
                # Reset counter after alerting to avoid alert flood
                consecutive_failures=0
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
