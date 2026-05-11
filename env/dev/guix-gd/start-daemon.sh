#!/usr/bin/env bash
# Start guix-daemon inside an existing overlayfs container namespace.
# Uses the PID stored at "${GUIX_GD_DEV_ROOT}/overlayfs-container.pid" to nsenter
# into the container and run the daemon.

set -o errexit     # -e: exit on error
set -o nounset     # -u: treat unset variables as errors
set -o pipefail    # return status of last failed command in a pipeline

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT:-${SCRIPT_DIR}/.dev-root}"
PIDFILE="${GUIX_GD_DEV_ROOT}/overlayfs-container.pid"
GUIX_GD_DAEMON_BIN="${GUIX_GD_DAEMON_BIN:-guix-daemon}"
GUIX_GD_DEV_SOCK="${GUIX_GD_DEV_SOCK:-/tmp/guix-gd-fallback.sock}"
# Extra args passed verbatim to guix-daemon.
# We keep --listen outside this variable so callers can set GUIX_GD_DEV_SOCK
# without having to override GUIX_GD_DAEMON_ARGS too.
# --disable-deduplication avoids hard-link issues in overlayfs upperdir.
GUIX_GD_DAEMON_ARGS="${GUIX_GD_DAEMON_ARGS:---disable-deduplication}"
GUIX_GD_GROUP="${GUIX_GD_GROUP:-guix-gd-build}"

# Validate pidfile exists
if [ ! -f "$PIDFILE" ]; then
    printf 'ERROR: pidfile not found: %s\n' "$PIDFILE" >&2
    exit 1
fi

# Read and sanitize PID (strip whitespace/newline)
PID="$(tr -d ' \t\n\r' < "$PIDFILE")"

# Validate PID is numeric
if ! printf '%s\n' "$PID" | grep -Eq '^[0-9]+$'; then
    printf 'ERROR: pidfile %s contains invalid PID: %s\n' "$PIDFILE" "$PID" >&2
    exit 2
fi

# Check process exists (use ps -p to match your request)
if ! ps -p "$PID" >/dev/null 2>&1; then
    printf 'ERROR: no process with PID %s. Overlayfs container not running?\n' "$PID" >&2
    exit 3
fi

# Ensure nsenter is available
if ! command -v nsenter >/dev/null 2>&1; then
    printf 'ERROR: nsenter not found in PATH. Install util-linux or ensure nsenter is available.\n' >&2
    exit 4
fi

printf 'Found overlayfs container PID: %s\n' "$PID"

# Explanation of the nsenter flags we use:
# --target <pid>  : target process to get namespaces from
# --all           : enter all namespaces (mount, uts, ipc, net, pid, cgroup, user, time, ...)
# --              : end of nsenter options; what follows is the command to run inside the namespaces
# We run `sudo` before nsenter to obtain the privileges required to enter namespaces, and we run
# `sudo` inside the namespace so that guix-daemon runs as root inside the container's namespaces.

# Start guix-daemon inside the overlayfs container namespace.
# You can override GUIX_GD_DAEMON_BIN and GUIX_GD_DAEMON_ARGS via the environment.
printf 'Running: sudo nsenter --target %s --all -- sudo %s %s\n' "$PID" "$GUIX_GD_DAEMON_BIN" "$GUIX_GD_DAEMON_ARGS"

exec sudo nsenter --target "$PID" --all -- sudo "$GUIX_GD_DAEMON_BIN" \
     --build-users-group=$GUIX_GD_GROUP \
     --listen=$GUIX_GD_DEV_SOCK \
     $GUIX_GD_DAEMON_ARGS
