#!/bin/sh
# Write unified diff between two files.

set -eu

HOST_PATH="${GXD_HOST_PATH:-/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin}"
PATH="$HOST_PATH"
export PATH

before="$1"
after="$2"
diff_file="$3"

if diff -u "$before" "$after" > "$diff_file"; then
  exit 0
fi

rc=$?
if [ "$rc" -eq 1 ]; then
  exit 0
fi

exit "$rc"
