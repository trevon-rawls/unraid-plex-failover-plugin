#!/bin/bash
# --- Plex Failover Environment Setup ---

STATE_DIR="/var/tmp/plex_failover"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Create empty files if they don't exist
: > "$STATE_DIR/prev_combined"
: > "$STATE_DIR/last_notify"
: > "$STATE_DIR/last_error_sig"
: > "$STATE_DIR/last_hb"

# Default mode file (auto, unless you set something else manually)
if [ ! -f "$STATE_DIR/mode" ]; then
  echo "auto" > "$STATE_DIR/mode"
fi

echo "Environment initialized under $STATE_DIR"
