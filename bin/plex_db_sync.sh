#!/bin/bash
# plex_db_sync.sh — Mirror Plex DB from primary → secondary when secondary is stopped.
# - Safe to run from cron or on a schedule.
# - Assumes official plexinc images & standard appdata layout.
# - Set DRY_RUN=1 for a preview (no changes).

set -u  # (no -e so we can control exit paths and log errors ourselves)

# === Config =================================================================
SRC="/mnt/user/appdata/Plex-Media-Server/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
DEST="/mnt/user/appdata/Plex-Media-Server-Secondary/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
CONTAINER="Plex-Media-Server-Secondary"

LOG_FILE="/var/log/plex_db_sync.log"
LOCK_FILE="/var/tmp/plex_db_sync.lock"

# Optional: DRY_RUN=1 rsyncs with -n (no changes).
DRY_RUN="${DRY_RUN:-0}"

# === Helpers =================================================================
ts()   { date "+%Y-%m-%d %H:%M:%S %Z"; }
log()  { echo "$(ts): $*" | tee -a "$LOG_FILE"; }
die()  { log "ERROR: $*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | tr -d '[:space:]' || echo "false"
}

# Optional: disable sync while backups run
DISABLE_FILE="/var/tmp/plex_backup_in_progress"
if [ -f "$DISABLE_FILE" ]; then
  log "Backup flag found ($DISABLE_FILE). Skipping database sync."
  exit 0
fi

# Prefer flock (fd 9), else mkdir lock
take_lock() {
  if have flock; then
    exec 9>"$LOCK_FILE" || die "Unable to open lock file: $LOCK_FILE"
    flock -n 9 || { log "Another sync is running (flock). Skipping."; exit 0; }
    # flock auto-releases when fd 9 closes on exit
  else
    if ! mkdir "$LOCK_FILE" 2>/dev/null; then
      log "Another sync is running (mkdir lock). Skipping."
      exit 0
    fi
    trap 'rmdir "$LOCK_FILE" 2>/dev/null || true' EXIT
  fi
}

nice_wrap() {
  # Use ionice/nice if available; otherwise run command as-is
  if have ionice; then
    ionice -c2 -n7 nice -n 10 "$@"
  else
    nice -n 10 "$@"
  fi
}

# === Start =================================================================
take_lock

have docker || die "docker not found in PATH."
have rsync  || die "rsync not found in PATH."

# Ensure paths exist
[ -d "$SRC" ]  || die "Source path missing: $SRC"
if [ ! -d "$DEST" ]; then
  log "Destination path missing: $DEST (creating...)"
  mkdir -p "$DEST" || die "Could not create $DEST"
fi

# Skip if secondary container is running
if [ "$(container_running "$CONTAINER")" = "true" ]; then
  log "Container $CONTAINER is running. No action taken."
  exit 0
fi

log "Container $CONTAINER is stopped. Starting database sync…"

# === rsync build =================================================================
# Flags:
#  -aH           : archive + preserve hard links
#  --delete      : mirror src→dest (dangerous if SRC wrong; double-check!)
#  --itemize-changes, --info=stats2,flist2,del2 : concise change + stats
#  --human-readable
#  --inplace     : rewrite large DB files in place (safer since container is stopped)
# Excludes common junk
RSYNC_ARGS=(
  -aH --delete
  --itemize-changes
  --info=stats2,flist2,del2
  --human-readable
  --inplace
  --exclude=".DS_Store"
  --exclude="lost+found"
  # add any other excludes here
)

# Dry-run?
if [ "$DRY_RUN" = "1" ]; then
  RSYNC_ARGS+=( -n )
  log "DRY_RUN=1 enabled: no changes will be made."
fi

# === Execute =================================================================
# Use arrays to preserve spaces in paths
SRC_DIR="$SRC/"
DEST_DIR="$DEST/"

# Capture output for analysis
if OUTPUT="$(nice_wrap rsync "${RSYNC_ARGS[@]}" -- "$SRC_DIR" "$DEST_DIR" 2>&1)"; then
  # Count changed items: lines beginning with itemize flags (first token like '>.d..t....')
  CHANGES="$(printf '%s\n' "$OUTPUT" | awk '/^[-dchslp\.][^ ]/ {print}' | wc -l | tr -d ' ')"
  [ "$DRY_RUN" = "1" ] && log "DRY-RUN completed. Would change items: $CHANGES" || log "Sync completed successfully. Changed items: $CHANGES"

  # Append final rsync stats block to log
  printf '%s\n' "$OUTPUT" | awk '/Number of files:|Number of regular files:|Number of created files:|Number of deleted files:|Total transferred file size:|Literal data:|Matched data:|File list size:|Total bytes sent:|Total bytes received:/' >> "$LOG_FILE"
  exit 0
else
  RC=$?
  log "ERROR: rsync failed with exit code $RC"
  printf '%s\n' "$OUTPUT" | tail -n 50 >> "$LOG_FILE"
  exit "$RC"
fi
