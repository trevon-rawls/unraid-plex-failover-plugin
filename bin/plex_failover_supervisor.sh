#!/bin/bash
# -----------------------------------------------------------------------------
# Plex in-container failover supervisor (heartbeat + multi-error + notify)
# -----------------------------------------------------------------------------
# Supervises two Plex containers (primary + secondary) so only one PMS runs.
#  • Starts primary on cold boot.
#  • In AUTO, promotes secondary if primary is unhealthy (process down or log errors).
#  • FORCE modes: force_primary / force_secondary.
#  • Clean logs: emits on change + heartbeat every HEARTBEAT_SECS.
#  • Throttled Unraid GUI notifications for promotions/restores/forced actions.
#
# Assumptions:
#   - Official Plex images: plexinc/pms-docker or plexinc/pms-docker:plexpass.
#   - Inside each container, /plex_service.sh (-u start, -d stop) controls PMS.
#   - Log locations match common layouts (see PLEX_LOG_PATHS below).
#
# Files/Paths:
#   - Mode file: /var/tmp/plex_failover/mode  (auto | force_primary | force_secondary)
#   - Log file:  /tmp/user.scripts/tmpScripts/Plex Failover Script/log.txt
#
# Author: Trevon Rawls
# -----------------------------------------------------------------------------

# === User Config =============================================================

PRIMARY_CONTAINER="Plex-Media-Server"
SECONDARY_CONTAINER="Plex-Media-Server-Secondary"

MODE_FILE="/var/tmp/plex_failover/mode"

# Log file for this supervisor (shown + persisted)
LOG_FILE="/tmp/user.scripts/tmpScripts/Plex Failover Script/log.txt"

# Loop pacing and small wait after start attempts
SLEEP_SECS=15              # choose 15-30s to align with heartbeat
WAIT_AFTER_START=3

# Heartbeat interval in seconds (0 disables). 15-39s recommended.
HEARTBEAT_SECS=15

# Enable debug lines (1 on, 0 off)
DEBUG=${DEBUG:-1}

# Multiple error signatures (case-insensitive regex). Add more as needed.
ERROR_PATTERNS=(
  "Unable to set up server"
  # "database disk image is malformed"
  # "FATAL.*migration"
)

# Common Plex log paths (inside containers). First existing path is used.
PLEX_LOG_PATHS=(
  "/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log"         # linuxserver.io
  "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" # official
)

# === Internals (shouldn't need edits) ========================================

# Ensure dirs/files exist
mkdir -p "$(dirname "$LOG_FILE")"
STATE_DIR="/var/tmp/plex_failover"
mkdir -p "$STATE_DIR"
[ -f "$MODE_FILE" ] || echo "auto" > "$MODE_FILE"

# Logging helpers
_log()   { echo "$(date): $*" | tee -a "$LOG_FILE" >/dev/null; }
_debug() { [ "$DEBUG" = "1" ] && echo "$(date): [DEBUG] $*" >> "$LOG_FILE"; }

# Notifications (Unraid)
THROTTLE_SECS=30
LAST_NOTIFY_FILE="$STATE_DIR/last_notify"
_send_notify() {
  # _send_notify <subject> <description> [icon]
  /usr/local/emhttp/webGui/scripts/notify \
    -e "Plex Failover" \
    -s "$1" \
    -d "$2" \
    -i "${3:-normal}" >/dev/null 2>&1 || true
}
_can_notify() {
  local now last
  now=$(date +%s)
  last=$(cat "$LAST_NOTIFY_FILE" 2>/dev/null || echo 0)
  [ $((now - last)) -ge $THROTTLE_SECS ]
}
_mark_notified() { date +%s > "$LAST_NOTIFY_FILE"; }

# Utilities
ctr_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }

ctr_start() {
  local ctr="$1"
  if ! ctr_running "$ctr"; then
    _debug "Starting container: $ctr"
    docker start "$ctr" >/dev/null 2>&1 || true
    sleep 1
  fi
  # Only start PMS if not already running
  if [ "$(_proc_state "$ctr")" != "running" ]; then
    _debug "Starting Plex in $ctr via /plex_service.sh -u"
    docker exec "$ctr" sh -lc '[ -x /plex_service.sh ] && /plex_service.sh -u' >/dev/null 2>&1 || true
    sleep "$WAIT_AFTER_START"
  fi
}

ctr_stop() {
  local ctr="$1"
  # Only stop PMS if it appears running
  if [ "$(_proc_state "$ctr")" = "running" ]; then
    _debug "Stopping Plex in $ctr via /plex_service.sh -d"
    docker exec "$ctr" sh -lc '[ -x /plex_service.sh ] && /plex_service.sh -d' >/dev/null 2>&1 || true
  fi
}

# Process presence only (BusyBox/procps compatible)
_proc_state() {
  local ctr="$1"
  docker exec "$ctr" sh -lc '
    if ps -ef 2>/dev/null; then
      ps -ef | grep -Ei "Plex Media Server" | grep -v grep >/dev/null
    elif ps aux 2>/dev/null; then
      ps aux | grep -Ei "Plex Media Server" | grep -v grep >/dev/null
    else
      ps | grep -Ei "Plex Media Server" | grep -v grep >/dev/null
    fi
  ' >/dev/null 2>&1
  [ $? -eq 0 ] && echo "running" || echo "stopped"
}

# Tail Plex log from first existing path; empty output if none found.
_tail_plex_log() {
  local ctr="$1"
  local script='
    for p in '"$(printf '%q ' "${PLEX_LOG_PATHS[@]}")"'; do
      if [ -f "$p" ]; then
        tail -n 200 "$p" 2>/dev/null || sed -n "1,200p" "$p" 2>/dev/null
        exit 0
      fi
    done
    exit 0
  '
  docker exec "$ctr" sh -lc "$script" 2>/dev/null
}

# Return "error" if ANY pattern matches recent logs, else "ok"
_logs_state() {
  local ctr="$1" log_out pat
  log_out="$(_tail_plex_log "$ctr")"
  [ -z "$log_out" ] && { echo "ok"; return; }
  for pat in "${ERROR_PATTERNS[@]}"; do
    if echo "$log_out" | grep -Eiq -- "$pat"; then
      _debug "$ctr: matched error pattern: $pat"
      echo "error"; return
    fi
  done
  echo "ok"
}

# Primary health: healthy | error | stopped
primary_health() {
  local proc logs
  proc="$(_proc_state "$PRIMARY_CONTAINER")"
  if [ "$proc" != "running" ]; then
    echo "stopped"; return
  fi
  logs="$(_logs_state "$PRIMARY_CONTAINER")"
  [ "$logs" = "ok" ] && echo "healthy" || echo "error"
}

mode_get() { tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null || echo "auto"; }

# Change-only + heartbeat emission
LAST_STATUS=""
LAST_HEARTBEAT_EPOCH=0
_emit_status() {
  local msg="$1"
  local now epoch_gap
  now=$(date +%s)
  epoch_gap=$(( now - LAST_HEARTBEAT_EPOCH ))
  if [ "$msg" != "$LAST_STATUS" ] || { [ "$HEARTBEAT_SECS" -gt 0 ] && [ "$epoch_gap" -ge "$HEARTBEAT_SECS" ]; }; then
    if [ "$msg" = "$LAST_STATUS" ]; then
      _log "[HEARTBEAT] $msg"
    else
      _log "$msg"
    fi
    LAST_STATUS="$msg"
    LAST_HEARTBEAT_EPOCH="$now"
  fi
}

# Graceful shutdown note
trap '_log "Supervisor exiting"; exit 0' INT TERM

# === Main loop ==============================================================
_log "Supervisor starting (DEBUG=$DEBUG; HEARTBEAT_SECS=$HEARTBEAT_SECS)"
while true; do
  MODE="$(mode_get)"

  # Measure states
  PRIMARY_HEALTH="$(primary_health)"                      # healthy | error | stopped
  P_PROC="$(_proc_state "$PRIMARY_CONTAINER")"            # running | stopped
  S_PROC="$(_proc_state "$SECONDARY_CONTAINER")"          # running | stopped
  ACTIONS=()

  case "$MODE" in
    auto)
      case "$PRIMARY_HEALTH" in
        healthy)
          # Primary good → ensure secondary down
          if [ "$S_PROC" = "running" ]; then
            ctr_stop "$SECONDARY_CONTAINER"
            ACTIONS+=("secondary-stopped"); S_PROC="stopped"
            if _can_notify; then
              _send_notify "Primary Restored" "Primary healthy; secondary stopped." "normal"
              _mark_notified
            fi
          fi
          ;;
        error)
          # Primary running but logs show fatal startup error → switch over
          ctr_stop "$PRIMARY_CONTAINER";     ACTIONS+=("primary-stopped");   P_PROC="stopped"
          ctr_start "$SECONDARY_CONTAINER";  ACTIONS+=("secondary-started"); S_PROC="running"
          if _can_notify; then
            _send_notify "Secondary Promoted" "Primary unhealthy: error detected in logs. Secondary started." "warning"
            _mark_notified
          fi
          ;;
        stopped)
          # Primary down → prefer starting primary first; warm it
          ctr_start "$PRIMARY_CONTAINER";    ACTIONS+=("primary-warming")
          # If you prefer instant promotion when the primary CONTAINER itself is down, uncomment:
          # if ! ctr_running "$PRIMARY_CONTAINER"; then
          #   ctr_start "$SECONDARY_CONTAINER"; ACTIONS+=("secondary-started"); S_PROC="running"
          #   if _can_notify; then
          #     _send_notify "Secondary Promoted" "Primary container stopped; secondary started." "warning"
          #     _mark_notified
          #   fi
          # fi
          ;;
      esac
      ;;
    force_primary)
      if [ "$P_PROC" != "running" ]; then
        ctr_start "$PRIMARY_CONTAINER"; ACTIONS+=("primary-forced"); P_PROC="running"
        if _can_notify; then
          _send_notify "Forced Primary" "Primary started by force_primary mode." "normal"
          _mark_notified
        fi
      fi
      if [ "$S_PROC" = "running" ]; then
        ctr_stop "$SECONDARY_CONTAINER"; ACTIONS+=("secondary-stopped"); S_PROC="stopped"
      fi
      ;;
    force_secondary)
      if [ "$S_PROC" != "running" ]; then
        ctr_start "$SECONDARY_CONTAINER"; ACTIONS+=("secondary-forced"); S_PROC="running"
        if _can_notify; then
          _send_notify "Forced Secondary" "Secondary started by force_secondary mode." "warning"
          _mark_notified
        fi
      fi
      if [ "$P_PROC" = "running" ]; then
        ctr_stop "$PRIMARY_CONTAINER"; ACTIONS+=("primary-stopped"); P_PROC="stopped"
      fi
      ;;
    *)
      MODE="auto"
      ;;
  esac

  _emit_status "mode=$MODE; primary=$PRIMARY_HEALTH; p_proc=$P_PROC; s_proc=$S_PROC${ACTIONS:+; action=${ACTIONS[*]}}"
  sleep "$SLEEP_SECS"
done
