#!/bin/bash
# Post-backup hook: remove pause flag so db_sync can run again.

set -euo pipefail

FLAG="/var/tmp/plex_backup_in_progress"

echo "[$(date)] Post-backup: removing flag $FLAG"
rm -f "$FLAG" || true

exit 0
