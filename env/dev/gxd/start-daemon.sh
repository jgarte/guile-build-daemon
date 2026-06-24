#!/bin/sh
# Start guix-daemon inside an existing rootless container namespace.

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

resolve_command_path() {
  candidate="$1"

  if [ -x "$candidate" ]; then
    readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
    return 0
  fi

  resolved="$(command -v "$candidate" 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    return 1
  fi

  readlink -f "$resolved" 2>/dev/null || printf '%s\n' "$resolved"
}

DAEMON_BIN="$(resolve_command_path "$GXD_DAEMON_BIN" 2>/dev/null || true)"
if [ -z "$DAEMON_BIN" ]; then
  printf 'ERROR: daemon binary not found: %s\n' "$GXD_DAEMON_BIN" >&2
  exit 5
fi

GROUP_ARG=''
if [ -n "$GXD_GROUP" ]; then
  if grep -q "^${GXD_GROUP}:" /etc/group; then
    GROUP_ARG="--build-users-group=${GXD_GROUP}"
  else
    printf 'WARNING: build users group not found: %s (continuing without --build-users-group)\n' "$GXD_GROUP" >&2
  fi
fi

printf 'Found container PID: %s\n' "$PID"
rm -f "$GXD_DEV_SOCK"
printf 'Running: nsenter --target %s --user --mount --preserve-credentials -- %s --listen=%s %s %s\n' \
  "$PID" "$DAEMON_BIN" "$GXD_DEV_SOCK" "$GROUP_ARG" "$GXD_DAEMON_ARGS"

set -- "$DAEMON_BIN" "--listen=$GXD_DEV_SOCK"
if [ -n "$GROUP_ARG" ]; then
  set -- "$@" "$GROUP_ARG"
fi
# shellcheck disable=SC2086
set -- "$@" $GXD_DAEMON_ARGS

exec nsenter --target "$PID" --user --mount --preserve-credentials -- "$@"
