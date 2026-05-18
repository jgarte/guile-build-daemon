#!/bin/sh
# Run a command inside a container and persist stdout/stderr/exit-code.

set -eu

HOST_PATH="${GUIX_GD_HOST_PATH:-/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin}"
PATH="$HOST_PATH"
export PATH

pid="$1"
socket="$2"
cmd="$3"
stdout_file="$4"
stderr_file="$5"
exit_file="$6"

rc=0
nsenter --target "$pid" --user --mount --preserve-credentials -- \
  env GUIX_DAEMON_SOCKET="$socket" \
  /bin/sh -lc "$cmd" \
  >"$stdout_file" 2>"$stderr_file" || rc=$?

printf '%s\n' "$rc" > "$exit_file"
