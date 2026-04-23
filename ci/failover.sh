#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shunt — DNS failover to secondary VPS
#
# Promotes the secondary VPS to active by:
# 1. Validating required Cloudflare API env vars
# 2. Checking secondary health via /healthz
# 3. Updating DNS A record via Cloudflare API
# 4. Polling DNS propagation (max 120s)
# 5. Verifying traffic hits secondary
# 6. Ensuring services are running on secondary
#
# Usage:
# ci/failover.sh              # Execute failover
# ci/failover.sh --dry-run    # Show what would happen without making changes
# ci/failover.sh --self-test  # Validate prerequisites
#
# Required env vars:
# CF_API_TOKEN         — Cloudflare API token
# CF_ZONE_ID           — Cloudflare zone ID
# CF_RECORD_ID         — DNS A record ID to update
# SHUNT_DOMAIN         — domain name (e.g., shunt.dev)
# SHUNT_SECONDARY_IP   — secondary VPS IP address
# SHUNT_SECONDARY_HOST — SSH hostname/IP of secondary VPS
# SHUNT_SECONDARY_PATH — project root on secondary (default: /root/shunt)
#
# Idempotent: if secondary is already active (DNS already points to it), exit 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_RECORD_ID="${CF_RECORD_ID:-}"
SHUNT_DOMAIN="${SHUNT_DOMAIN:-}"
SHUNT_SECONDARY_IP="${SHUNT_SECONDARY_IP:-}"
SHUNT_SECONDARY_HOST="${SHUNT_SECONDARY_HOST:-}"
SHUNT_SECONDARY_PATH="${SHUNT_SECONDARY_PATH:-/root/shunt}"

DNS_PROPAGATION_TIMEOUT=120
DNS_POLL_INTERVAL=5
SSH_OPTIONS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
SSH_KEY="${SHUNT_FAILOVER_SSH_KEY:-$HOME/.ssh/id_shunt_sync}"

DRY_RUN=false

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
local level="$1"; shift
printf '{"time":"%s","level":"%s","msg":"%s"}\n' \
"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

info() { log "info" "$@"; }
warn() { log "warn" "$@"; }
error() { log "error" "$@"; }

# ── Validate ─────────────────────────────────────────────────────────────────

validate_config() {
local missing=0

for var in CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID SHUNT_DOMAIN SHUNT_SECONDARY_IP SHUNT_SECONDARY_HOST; do
if [ -z "${!var:-}" ]; then
error "Required env var not set: $var"
missing=$((missing + 1))
fi
done

if [ "$missing" -gt 0 ]; then
error "Missing $missing required env var(s)"
return 1
fi

if ! command -v curl >/dev/null 2>&1; then
error "curl not found in PATH"
return 1
fi

if ! command -v ssh >/dev/null 2>&1; then
error "ssh not found in PATH"
return 1
fi

info "All required env vars and tools present"
}

# ── Secondary health check ──────────────────────────────────────────────────

check_secondary_health() {
local url="http://${SHUNT_SECONDARY_HOST}:80/healthz"

info "Checking secondary health: $url"

local http_code
http_code="$(curl -sf -o /dev/null -w '%{http_code}' --connect-timeout 10 "$url" 2>/dev/null || true)"

if [ "$http_code" = "200" ]; then
info "Secondary health check passed (HTTP 200)"
return 0
else
error "Secondary health check failed (HTTP ${http_code:-no response})"
return 1
fi
}

# ── Check if secondary is already active ─────────────────────────────────────

is_secondary_already_active() {
local current_ip
current_ip="$(dig +short "$SHUNT_DOMAIN" A 2>/dev/null | head -n1 || true)"

if [ "$current_ip" = "$SHUNT_SECONDARY_IP" ]; then
info "DNS already points to secondary IP ($SHUNT_SECONDARY_IP)"
return 0
else
return 1
fi
}

# ── DNS update via Cloudflare API ────────────────────────────────────────────

update_dns() {
info "Updating DNS A record: $SHUNT_DOMAIN -> $SHUNT_SECONDARY_IP"

if [ "$DRY_RUN" = true ]; then
info "[DRY RUN] Would call Cloudflare API: PUT /client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID"
info "[DRY RUN] Body: {\"type\":\"A\",\"name\":\"$SHUNT_DOMAIN\",\"content\":\"$SHUNT_SECONDARY_IP\",\"ttl\":60,\"proxied\":false}"
return 0
fi

local response
response="$(curl -sf -X PUT \
"https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" \
-H "Authorization: Bearer ${CF_API_TOKEN}" \
-H "Content-Type: application/json" \
--data "{\"type\":\"A\",\"name\":\"${SHUNT_DOMAIN}\",\"content\":\"${SHUNT_SECONDARY_IP}\",\"ttl\":60,\"proxied\":false}" \
2>&1)" || {
error "Cloudflare API request failed"
error "Response: $response"
return 1
}

local success
success="$(echo "$response" | jq -r '.success' 2>/dev/null || echo "false")"

if [ "$success" = "true" ]; then
info "Cloudflare DNS update succeeded"
else
error "Cloudflare DNS update failed"
error "Response: $response"
return 1
fi
}

# ── DNS propagation polling ──────────────────────────────────────────────────

wait_for_dns_propagation() {
info "Waiting for DNS propagation (timeout=${DNS_PROPAGATION_TIMEOUT}s)"

local elapsed=0

while [ "$elapsed" -lt "$DNS_PROPAGATION_TIMEOUT" ]; do
local resolved_ip
resolved_ip="$(dig +short "$SHUNT_DOMAIN" A 2>/dev/null | head -n1 || true)"

if [ "$resolved_ip" = "$SHUNT_SECONDARY_IP" ]; then
info "DNS propagated after ${elapsed}s ($SHUNT_DOMAIN -> $SHUNT_SECONDARY_IP)"
return 0
fi

info "DNS not yet propagated (resolved: ${resolved_ip:-none}, expected: $SHUNT_SECONDARY_IP), waiting ${DNS_POLL_INTERVAL}s"
sleep "$DNS_POLL_INTERVAL"
elapsed=$((elapsed + DNS_POLL_INTERVAL))
done

error "DNS propagation timed out after ${DNS_PROPAGATION_TIMEOUT}s"
return 1
}

# ── Verify traffic hits secondary ────────────────────────────────────────────

verify_secondary_traffic() {
local url="http://${SHUNT_DOMAIN}/healthz"

info "Verifying traffic hits secondary: $url"

local http_code
http_code="$(curl -sf -o /dev/null -w '%{http_code}' --connect-timeout 10 "$url" 2>/dev/null || true)"

if [ "$http_code" = "200" ]; then
info "Verification passed: $SHUNT_DOMAIN returns HTTP 200"
return 0
else
error "Verification failed: $SHUNT_DOMAIN returned HTTP ${http_code:-no response}"
return 1
fi
}

# ── Ensure services on secondary ─────────────────────────────────────────────

ensure_secondary_services() {
info "Ensuring services are running on secondary"

if [ "$DRY_RUN" = true ]; then
info "[DRY RUN] Would SSH to $SHUNT_SECONDARY_HOST and run: cd $SHUNT_SECONDARY_PATH && docker compose up -d"
return 0
fi

ssh $SSH_OPTIONS -i "$SSH_KEY" "$SHUNT_SECONDARY_HOST" \
"cd $SHUNT_SECONDARY_PATH && docker compose up -d" 2>&1 || {
error "Failed to start services on secondary via SSH"
return 1
}

info "Secondary services started"
}

# ── Self-test ────────────────────────────────────────────────────────────────

do_self_test() {
info "Running self-test"

for tool in curl ssh dig jq; do
if ! command -v "$tool" >/dev/null 2>&1; then
error "Required tool not found: $tool"
return 1
fi
done
info "All required tools available"

local missing=0
for var in CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID SHUNT_DOMAIN SHUNT_SECONDARY_IP SHUNT_SECONDARY_HOST; do
if [ -z "${!var:-}" ]; then
warn "Env var not set: $var (required for production failover)"
missing=$((missing + 1))
fi
done

if [ "$missing" -gt 0 ]; then
warn "Missing $missing env var(s) — required for production failover"
fi

if [ -f "$SSH_KEY" ]; then
info "SSH key found: $SSH_KEY"
else
warn "SSH key not found at $SSH_KEY (install for production failover)"
fi

info "Self-test PASSED (prerequisites validated, set Cloudflare env vars for live failover)"
return 0
}

# ── Main failover flow ───────────────────────────────────────────────────────

main() {
validate_config || return 1

if is_secondary_already_active; then
info "Secondary is already the active node — no failover needed"
return 0
fi

info "Starting failover to secondary (dry_run=${DRY_RUN})"

check_secondary_health || {
error "Secondary is not healthy — aborting failover"
return 1
}

update_dns || return 1

if [ "$DRY_RUN" = true ]; then
info "[DRY RUN] Would poll DNS propagation and verify traffic"
info "[DRY RUN] Failover dry run complete"
return 0
fi

wait_for_dns_propagation || return 1

verify_secondary_traffic || {
warn "Traffic verification failed — secondary may need more time"
warn "Check DNS cache and secondary services manually"
}

ensure_secondary_services || warn "Could not verify secondary services via SSH"

info "Failover complete: $SHUNT_DOMAIN -> $SHUNT_SECONDARY_IP"
}

# ── Argument parsing ─────────────────────────────────────────────────────────

for arg in "$@"; do
case "$arg" in
--dry-run)
DRY_RUN=true
;;
--self-test)
do_self_test
exit $?
;;
--)
break
;;
*)
echo "Usage: $0 [--dry-run|--self-test]" >&2
exit 1
;;
esac
done

main
