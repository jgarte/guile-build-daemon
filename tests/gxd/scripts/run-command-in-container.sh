#!/bin/sh
# Run a command inside a container and persist stdout/stderr/exit-code.

set -eu

HOST_PATH="${GUIX_GD_HOST_PATH:-/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin}"
PATH="$HOST_PATH"
export PATH

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

pid="$1"
socket="$2"
cmd="$3"
stdout_file="$4"
stderr_file="$5"
exit_file="$6"

GUIX_BIN="${GUIX_GD_TEST_GUIX_BIN:-}"
if [ -z "$GUIX_BIN" ]; then
  GUIX_BIN="$(resolve_command_path guix 2>/dev/null || true)"
fi

if [ -n "$GUIX_BIN" ]; then
  case "$cmd" in
    guix)
      cmd="$GUIX_BIN"
      ;;
    guix\ *)
      cmd="$GUIX_BIN${cmd#guix}"
      ;;
  esac
fi

rc=0
nsenter --target "$pid" --user --mount --preserve-credentials -- \
  env GUIX_DAEMON_SOCKET="$socket" \
  /bin/sh -lc "$cmd" \
  >"$stdout_file" 2>"$stderr_file" || rc=$?

printf '%s\n' "$rc" > "$exit_file"
