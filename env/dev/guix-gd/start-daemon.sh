#!/bin/sh
# Start guix-daemon inside an existing rootless overlayfs namespace.

set -eu
set -o pipefail 2>/dev/null || true

GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT:-/tmp/guix-gd-overlayfs-${USER:-user}}"
PIDFILE="${GUIX_GD_DEV_ROOT}/overlayfs-container.pid"
GUIX_GD_DAEMON_BIN="${GUIX_GD_DAEMON_BIN:-guix-daemon}"
GUIX_GD_DEV_SOCK="${GUIX_GD_DEV_SOCK:-/tmp/guix-gd-fallback-${USER:-user}.sock}"
GUIX_GD_DAEMON_ARGS="${GUIX_GD_DAEMON_ARGS:---disable-chroot --disable-deduplication}"
GUIX_GD_GROUP="${GUIX_GD_GROUP:-guix-gd-build}"

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
  printf 'ERROR: no process with PID %s. Overlayfs container not running?\n' "$PID" >&2
  exit 3
fi

if ! command -v nsenter >/dev/null 2>&1; then
  printf 'ERROR: nsenter not found in PATH.\n' >&2
  exit 4
fi

GROUP_ARG=''
if [ -n "$GUIX_GD_GROUP" ]; then
  if grep -q "^${GUIX_GD_GROUP}:" /etc/group; then
    GROUP_ARG="--build-users-group=${GUIX_GD_GROUP}"
  else
    printf 'WARNING: build users group not found: %s (continuing without --build-users-group)\n' "$GUIX_GD_GROUP" >&2
  fi
fi

printf 'Found overlayfs container PID: %s\n' "$PID"
rm -f "$GUIX_GD_DEV_SOCK"
printf 'Running: nsenter --target %s --user --mount --preserve-credentials -- %s --listen=%s %s %s\n' \
  "$PID" "$GUIX_GD_DAEMON_BIN" "$GUIX_GD_DEV_SOCK" "$GROUP_ARG" "$GUIX_GD_DAEMON_ARGS"

set -- "$GUIX_GD_DAEMON_BIN" "--listen=$GUIX_GD_DEV_SOCK"
if [ -n "$GROUP_ARG" ]; then
  set -- "$@" "$GROUP_ARG"
fi
# shellcheck disable=SC2086
set -- "$@" $GUIX_GD_DAEMON_ARGS

exec nsenter --target "$PID" --user --mount --preserve-credentials -- "$@"
