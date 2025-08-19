#!/bin/bash
# Pre-backup hook: signal db_sync to pause, optionally wait for an active sync to finish.

set -euo pipefail

FLAG="/var/tmp/plex_backup_in_progress"
LOCK="/var/tmp/plex_db_sync.lock"

echo "[$(date)] Pre-backup: creating flag $FLAG"
: > "$FLAG"

WAIT_SECS="${WAIT_SECS:-60}"
SLEEP_STEP=2
elapsed=0

while [ -e "$LOCK" ] || lsof -t "$LOCK" >/dev/null 2>&1; do
  if [ $elapsed -ge $WAIT_SECS ]; then
    echo "[$(date)] Pre-backup: timeout waiting for existing sync to finish; continuing backup with sync paused."
    break
  fi
  echo "[$(date)] Pre-backup: sync lock present, waiting..."
  sleep $SLEEP_STEP
  elapsed=$((elapsed + SLEEP_STEP))
done

exit 0
