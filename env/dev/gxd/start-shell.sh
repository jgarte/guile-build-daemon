#!/bin/sh
# Start a shell inside an existing rootless container namespace.

set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/config.defaults.sh"

PIDFILE="${GXD_DEV_ROOT}/overlayfs-container.pid"

if [ ! -f "$PIDFILE" ]; then
  printf 'ERROR: pidfile not found: %s\n' "$PIDFILE" >&2
  exit 1
fi

PID="$(tr -d ' \t\n\r' < "$PIDFILE")"

case "$PID" in
  ''|*[!0-9]*)
    printf 'ERROR: pidfile %s contains invalid PID: %s\n' "$PIDFILE" "$PID" >&2
    exit 2
    ;;
esac

if ! ps -p "$PID" >/dev/null 2>&1; then
  printf 'ERROR: no process with PID %s. Container not running?\n' "$PID" >&2
  exit 3
fi

if ! command -v nsenter >/dev/null 2>&1; then
  printf 'ERROR: nsenter not found in PATH.\n' >&2
  exit 4
fi

printf 'Found container PID: %s\n' "$PID"
printf 'Running: nsenter --target %s --user --mount --preserve-credentials -- /bin/sh\n' "$PID"

exec nsenter --target "$PID" --user --mount --preserve-credentials -- /bin/sh
