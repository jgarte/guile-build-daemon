#!/bin/sh
# Stop the overlayfs namespace session recorded in overlayfs-container.pid.

set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/config.defaults.sh"

PID_FILE="${1:-${GUIX_GD_DEV_ROOT}/overlayfs-container.pid}"

if [ ! -r "$PID_FILE" ]; then
  printf 'No pid file: %s\n' "$PID_FILE"
  exit 0
fi

read -r PID < "$PID_FILE" || PID=''
PID="$(printf '%s' "$PID" | tr -d '[:space:]')"

case "$PID" in
  ''|*[!0-9]*)
    printf 'ERROR: invalid PID in %s: %s\n' "$PID_FILE" "$PID" >&2
    exit 1
    ;;
esac

if ! kill -0 "$PID" 2>/dev/null; then
  rm -f "$PID_FILE"
  printf 'Removed stale pid file: %s\n' "$PID_FILE"
  exit 0
fi

PGID="$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d '[:space:]' || true)"

send_signal() {
  signal="$1"
  if [ -n "$PGID" ] && kill -s "$signal" -- "-$PGID" 2>/dev/null; then
    return 0
  fi
  kill -s "$signal" "$PID" 2>/dev/null
}

wait_for_exit() {
  limit="$1"
  i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  ! kill -0 "$PID" 2>/dev/null
}

printf 'Stopping overlayfs container PID: %s\n' "$PID"
send_signal TERM || {
  printf 'ERROR: failed to send SIGTERM to PID %s\n' "$PID" >&2
  exit 1
}

if ! wait_for_exit 5; then
  printf 'PID %s still running; sending SIGKILL\n' "$PID"
  send_signal KILL || {
    printf 'ERROR: failed to send SIGKILL to PID %s\n' "$PID" >&2
    exit 1
  }
  if ! wait_for_exit 2; then
    printf 'ERROR: PID %s is still alive after SIGKILL\n' "$PID" >&2
    exit 1
  fi
fi

rm -f "$PID_FILE"
printf 'Stopped overlayfs container and removed %s\n' "$PID_FILE"
