#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shunt — SQLite backup script with gzip compression
#
# Performs a consistent SQLite backup using .backup, then gzip-compresses
# the result. Supports --verify to check backup integrity and --self-test
# for CI validation.
#
# Usage:
#   ci/backup.sh              # Create a backup
#   ci/backup.sh --verify     # Verify the latest backup
#   ci/backup.sh --self-test  # Run self-test (creates temp DB, backs up, verifies)
#
# Idempotent: safe to re-run at any point.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

SHUNT_DB_PATH="${SHUNT_DB_PATH:-$PROJECT_ROOT/data/shunt.db}"
SHUNT_BACKUP_DIR="${SHUNT_BACKUP_DIR:-$PROJECT_ROOT/backups}"
SHUNT_BACKUP_RETENTION_DAYS="${SHUNT_BACKUP_RETENTION_DAYS:-30}"

DB_LOCK_RETRIES=3
DB_LOCK_RETRY_SLEEP=5

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
  local level="$1"; shift
  printf '{"time":"%s","level":"%s","msg":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

info() { log "info" "$@"; }
warn() { log "warn" "$@"; }
error() { log "error" "$@"; }

# ── Backup ───────────────────────────────────────────────────────────────────

do_backup() {
  if [ ! -f "$SHUNT_DB_PATH" ]; then
    error "Database file not found: $SHUNT_DB_PATH"
    return 1
  fi

  mkdir -p "$SHUNT_BACKUP_DIR"

  if [ ! -w "$SHUNT_BACKUP_DIR" ]; then
    error "Backup directory not writable: $SHUNT_BACKUP_DIR"
    return 1
  fi

  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local backup_path="$SHUNT_BACKUP_DIR/shunt-${timestamp}.db.gz"
  local backup_temp="${backup_path%.gz}.tmp"

  # Clean up temp file on exit
  cleanup() {
    rm -f "$backup_temp"
  }
  trap cleanup EXIT

  info "Starting backup of $SHUNT_DB_PATH"

  # sqlite3 .backup with lock retry
  local attempt=1
  while [ "$attempt" -le "$DB_LOCK_RETRIES" ]; do
    if sqlite3 "$SHUNT_DB_PATH" ".backup '$backup_temp'" 2>/dev/null; then
      info "SQLite backup succeeded (attempt $attempt)"
      break
    fi

    if [ "$attempt" -eq "$DB_LOCK_RETRIES" ]; then
      error "SQLite backup failed after $DB_LOCK_RETRIES attempts (database locked)"
      return 1
    fi

    warn "SQLite backup attempt $attempt failed (database locked), retrying in ${DB_LOCK_RETRY_SLEEP}s"
    sleep "$DB_LOCK_RETRY_SLEEP"
    attempt=$((attempt + 1))
  done

  gzip -c "$backup_temp" > "$backup_path"
  rm -f "$backup_temp"
  trap - EXIT

  local size
  size="$(stat -c%s "$backup_path" 2>/dev/null || stat -f%z "$backup_path" 2>/dev/null || echo "unknown")"
  info "Backup complete: $backup_path (${size} bytes)"

  # Retention: delete backups older than SHUNT_BACKUP_RETENTION_DAYS
  local deleted=0
  while IFS= read -r -d '' old_backup; do
    rm -f "$old_backup"
    deleted=$((deleted + 1))
  done < <(find "$SHUNT_BACKUP_DIR" -name 'shunt-*.db.gz' -type f -mtime +"$SHUNT_BACKUP_RETENTION_DAYS" -print0 2>/dev/null)

  if [ "$deleted" -gt 0 ]; then
    info "Retention cleanup: removed $deleted backup(s) older than ${SHUNT_BACKUP_RETENTION_DAYS} days"
  fi

  return 0
}

# ── Verify ───────────────────────────────────────────────────────────────────

do_verify() {
local latest_backup
latest_backup="$(find "$SHUNT_BACKUP_DIR" -name 'shunt-*.db.gz' -type f 2>/dev/null | sort -r | head -n 1 || true)"

if [ -z "$latest_backup" ]; then
error "No backup files found in $SHUNT_BACKUP_DIR"
return 1
fi

info "Verifying backup: $latest_backup"

local temp_file
temp_file="$(mktemp /tmp/shunt-verify-XXXXXX.db)"
local verify_cleanup_temp="$temp_file"

cleanup() {
rm -f "$verify_cleanup_temp"
}
trap cleanup EXIT

gunzip -c "$latest_backup" > "$temp_file"

local result
result="$(sqlite3 "$temp_file" "PRAGMA integrity_check;" 2>&1)"

if [ "$result" = "ok" ]; then
info "Backup integrity check passed: $latest_backup"
trap - EXIT
return 0
else
error "Backup integrity check FAILED: $latest_backup — $result"
trap - EXIT
return 1
fi
}

# ── Self-test ────────────────────────────────────────────────────────────────

do_self_test() {
  info "Running self-test"

  # Check required tools
  for tool in sqlite3 gzip gunzip find stat; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      error "Required tool not found: $tool"
      return 1
    fi
  done
  info "All required tools available"

  # Create temp directories
  local test_root
  test_root="$(mktemp -d /tmp/shunt-backup-test-XXXXXX)"
  cleanup() {
    rm -rf "$test_root"
  }
  trap cleanup EXIT

  local test_db_dir="$test_root/data"
  local test_backup_dir="$test_root/backups"
  mkdir -p "$test_db_dir" "$test_backup_dir"

  # Create a test database
  local test_db="$test_db_dir/shunt.db"
  sqlite3 "$test_db" "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT); INSERT INTO test VALUES (1, 'hello');"
  info "Test database created: $test_db"

  # Override config for test
  SHUNT_DB_PATH="$test_db"
  SHUNT_BACKUP_DIR="$test_backup_dir"
  SHUNT_BACKUP_RETENTION_DAYS=30

  # Test backup
  if ! do_backup; then
    error "Self-test FAILED: backup failed"
    return 1
  fi

  # Verify backup file exists
  local backup_count
  backup_count="$(find "$test_backup_dir" -name 'shunt-*.db.gz' -type f | wc -l)"
  if [ "$backup_count" -ne 1 ]; then
    error "Self-test FAILED: expected 1 backup file, found $backup_count"
    return 1
  fi
  info "Self-test: backup file created successfully"

  # Test verify
  if ! do_verify; then
    error "Self-test FAILED: verify failed"
    return 1
  fi
  info "Self-test: backup verification passed"

# Verify backup contents
local latest_backup
latest_backup="$(find "$test_backup_dir" -name 'shunt-*.db.gz' -type f | sort -r | head -n 1)"
local temp_verify
temp_verify="$(mktemp /tmp/shunt-selftest-verify-XXXXXX.db)"
gunzip -c "$latest_backup" > "$temp_verify"
local row_count
row_count="$(sqlite3 "$temp_verify" "SELECT COUNT(*) FROM test;")"
rm -f "$temp_verify"

if [ "$row_count" -ne 1 ]; then
error "Self-test FAILED: expected 1 row in backup, found $row_count"
return 1
fi
info "Self-test: backup data integrity confirmed (1 row)"

trap - EXIT
rm -rf "$test_root"

info "Self-test PASSED"
return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --verify)
    do_verify
    ;;
  --self-test)
    do_self_test
    ;;
  "")
    do_backup
    ;;
  *)
    echo "Usage: $0 [--verify|--self-test]" >&2
    exit 1
    ;;
esac
