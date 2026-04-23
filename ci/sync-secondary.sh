#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shunt — rsync application state from primary to secondary VPS
#
# Syncs data/, cfg/, and backups/ directories from the primary node
# to the secondary using rsync over SSH. The --delete flag ensures
# the secondary mirrors the primary exactly.
#
# Usage:
#   ci/sync-secondary.sh             # Sync to secondary
#   ci/sync-secondary.sh --self-test # Validate prerequisites
#
# Required env vars:
#   SHUNT_SECONDARY_HOST — SSH hostname/IP of secondary VPS
#   SHUNT_SECONDARY_PATH — project root on secondary (default: /root/shunt)
#
# SSH key: ~/.ssh/id_shunt_sync (must be installed on secondary)
#
# Idempotent: safe to re-run; --delete ensures secondary matches primary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

SHUNT_SECONDARY_HOST="${SHUNT_SECONDARY_HOST:-}"
SHUNT_SECONDARY_PATH="${SHUNT_SECONDARY_PATH:-/root/shunt}"
SSH_KEY="${SHUNT_SYNC_SSH_KEY:-$HOME/.ssh/id_shunt_sync}"
SSH_OPTIONS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
RSYNC_TIMEOUT=300

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
  if [ -z "$SHUNT_SECONDARY_HOST" ]; then
    error "SHUNT_SECONDARY_HOST is not set"
    return 1
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    error "rsync not found in PATH"
    return 1
  fi

  if [ ! -f "$SSH_KEY" ]; then
    warn "SSH key not found at $SSH_KEY (will use default SSH config)"
  fi
}

# ── SSH connectivity check ───────────────────────────────────────────────────

check_ssh_connectivity() {
  info "Checking SSH connectivity to $SHUNT_SECONDARY_HOST"
  if ssh $SSH_OPTIONS -i "$SSH_KEY" "$SHUNT_SECONDARY_HOST" "echo ok" >/dev/null 2>&1; then
    info "SSH connectivity confirmed"
    return 0
  else
    error "Cannot connect to $SHUNT_SECONDARY_HOST via SSH"
    return 1
  fi
}

# ── Sync ─────────────────────────────────────────────────────────────────────

do_sync() {
  validate_config || return 1
  check_ssh_connectivity || return 1

  local start_time
  start_time="$(date +%s)"

  local sync_paths=("$PROJECT_ROOT/data/" "$PROJECT_ROOT/cfg/" "$PROJECT_ROOT/backups/")

  for sync_path in "${sync_paths[@]}"; do
    local dir_name
    dir_name="$(basename "$sync_path")"

    if [ ! -d "$sync_path" ]; then
      warn "Local directory $sync_path does not exist, skipping"
      continue
    fi

    info "Syncing $dir_name/ to $SHUNT_SECONDARY_HOST:$SHUNT_SECONDARY_PATH/$dir_name/"

    rsync -az --delete \
      --timeout="$RSYNC_TIMEOUT" \
      -e "ssh $SSH_OPTIONS -i $SSH_KEY" \
      "$sync_path" \
      "$SHUNT_SECONDARY_HOST:$SHUNT_SECONDARY_PATH/" \
      2>&1 | while IFS= read -r line; do
        info "rsync $dir_name: $line"
      done

    info "Sync of $dir_name/ complete"
  done

  local end_time
  end_time="$(date +%s)"
  local elapsed=$((end_time - start_time))
  info "All syncs complete in ${elapsed}s"
}

# ── Self-test ────────────────────────────────────────────────────────────────

do_self_test() {
  info "Running self-test"

  # Check required tools
  for tool in rsync ssh; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      error "Required tool not found: $tool"
      return 1
    fi
  done
  info "All required tools available"

  # Check local directories
  for dir in data cfg backups; do
    if [ -d "$PROJECT_ROOT/$dir" ]; then
      if [ ! -r "$PROJECT_ROOT/$dir" ]; then
        error "Directory not readable: $PROJECT_ROOT/$dir"
        return 1
      fi
      info "Directory OK: $PROJECT_ROOT/$dir"
    else
      warn "Directory does not exist: $PROJECT_ROOT/$dir (will be created on first sync)"
    fi
  done

  # Check SSH key
  if [ -f "$SSH_KEY" ]; then
    info "SSH key found: $SSH_KEY"
  else
    warn "SSH key not found at $SSH_KEY (install for production sync)"
  fi

  # Validate env vars
  if [ -z "$SHUNT_SECONDARY_HOST" ]; then
    warn "SHUNT_SECONDARY_HOST not set (required for production sync)"
  else
    info "SHUNT_SECONDARY_HOST: $SHUNT_SECONDARY_HOST"
  fi

  info "Self-test PASSED (prerequisites validated, set SHUNT_SECONDARY_HOST for live sync)"
  return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --self-test)
    do_self_test
    ;;
  "")
    do_sync
    ;;
  *)
    echo "Usage: $0 [--self-test]" >&2
    exit 1
    ;;
esac
