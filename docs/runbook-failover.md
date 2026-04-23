# Shunt — Failover Runbook

SPDX-License-Identifier: AGPL-3.0-only

## Failover Procedure

### Automated Failover

Run the failover script to promote the secondary VPS to active:

```bash
# Dry run first to verify config
ci/failover.sh --dry-run

# Execute failover
ci/failover.sh
```

The script performs these steps automatically:

1. Validates all required Cloudflare env vars (`CF_API_TOKEN`, `CF_ZONE_ID`, `CF_RECORD_ID`, `SHUNT_DOMAIN`, `SHUNT_SECONDARY_IP`, `SHUNT_SECONDARY_HOST`)
2. Checks secondary health via `http://$SECONDARY_HOST:80/healthz`
3. Updates DNS A record via Cloudflare API (TTL=60)
4. Polls DNS propagation (max 120s)
5. Verifies traffic reaches secondary
6. Ensures Docker services are running on secondary

If the secondary is already active (DNS already points to it), the script exits 0 immediately.

### Manual Failover

If the script is unavailable, follow these steps:

1. **Verify secondary is healthy:**
   ```bash
   curl -sf http://SECONDARY_HOST:80/healthz
   ```

2. **Update DNS A record** in Cloudflare dashboard:
   - Type: A
   - Name: your domain
   - Content: secondary IP
   - TTL: 60

3. **Wait for DNS propagation** (up to 120s with 60s TTL):
   ```bash
   dig +short shunt.dev A
   ```

4. **Verify traffic hits secondary:**
   ```bash
   curl -sf http://shunt.dev/healthz
   ```

5. **Ensure services on secondary:**
   ```bash
   ssh SECONDARY_HOST "cd /root/shunt && docker compose up -d"
   ```

## Rollback Procedure

To roll back a blue-green deployment (not a DNS failover):

```bash
ci/rollback.sh
```

This switches Caddy back to the previous color and updates `cfg/active-color`.

To revert a DNS failover (point DNS back to primary):

```bash
# Set env vars to primary IP and run failover in reverse
SHUNT_SECONDARY_IP=PRIMARY_IP ci/failover.sh
```

## Backup Restore Procedure

### Restore from a gzipped backup

1. **Stop services:**
   ```bash
   cd /root/shunt
   docker compose down
   ```

2. **Restore the database:**
   ```bash
   gunzip -c backups/shunt-YYYYMMDDTHHMMSSZ.db.gz > data/shunt.db
   ```

3. **Verify integrity:**
   ```bash
   sqlite3 data/shunt.db "PRAGMA integrity_check;"
   ```
   Expected output: `ok`

4. **Restart services:**
   ```bash
   docker compose up -d
   ```

5. **Verify health:**
   ```bash
   curl -sf http://localhost/healthz
   ```

### Verify backup integrity (without restoring)

```bash
ci/backup.sh --verify
```

This gunzips the latest backup to a temp file, runs `PRAGMA integrity_check`, and cleans up.

## Split-Brain Prevention

Split-brain occurs when both primary and secondary accept traffic independently. Prevent it by:

1. **Single DNS A record** — Only one A record exists for the domain. The failover script updates this single record, never creates a second one.

2. **TTL=60** — Low TTL ensures DNS caches expire quickly, preventing stale routing to the old node.

3. **Primary shutdown on failover** — After confirming secondary is active, stop services on the primary:
   ```bash
   ssh PRIMARY_HOST "cd /root/shunt && docker compose down"
   ```

4. **Active color marker** — `cfg/active-color` tracks which color is active locally. After failover, update the secondary's marker:
   ```bash
   ssh SECONDARY_HOST "echo blue > /root/shunt/cfg/active-color"
   ```

5. **Health monitor** — `ci/health-monitor.sh` detects when the local node is unhealthy. Do NOT run it on both nodes simultaneously after failover.

6. **Lock file** — Consider adding a sentinel file (e.g., `/tmp/shunt-active-node`) that the failover script checks. Only the node with this file should accept responsibility for the domain.

## DNS TTL Guidance

- **Production TTL: 60 seconds** — This allows failover to complete within 2 minutes. The failover script sets TTL=60 when updating the Cloudflare record.
- **Pre-failover check** — Verify the current TTL before an emergency. If it was set higher (e.g., 3600), propagation will take longer.
- **Cloudflare proxy** — The failover script sets `proxied: false` to ensure DNS resolves directly to the VPS IP. If Cloudflare proxying is enabled, DNS changes may take longer to propagate through Cloudflare's edge network.
- **Caching layers** — Downstream DNS resolvers may cache beyond TTL. After failover, allow up to 5 minutes for full propagation even with TTL=60.
- **Monitoring** — Use `dig +short DOMAIN A` from multiple locations to confirm propagation. The failover script polls locally; for cross-region verification, use external tools like `nslookup` from different networks.

## Cron Schedules

Install the crontab for automated backup and sync:

```bash
crontab cfg/crontab
```

This sets up:

- **Backup every 6 hours** (00:00, 06:00, 12:00, 18:00 UTC) via `ci/backup.sh`
- **Sync every 15 minutes** via `ci/sync-secondary.sh`

Logs are written to `/var/log/shunt-backup.log` and `/var/log/shunt-sync.log`.
