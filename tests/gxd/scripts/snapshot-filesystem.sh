#!/bin/sh
# Write deterministic filesystem snapshot for a test root.

set -eu

HOST_PATH="${GXD_HOST_PATH:-/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin}"
PATH="$HOST_PATH"
export PATH

root="$1"
out="$2"
tmp="${out}.tmp"

: > "$tmp"
for d in "$root/gnu/store-upper" "$root/var/guix" "$root/etc/guix"; do
  if [ -e "$d" ]; then
    find "$d" -printf '%p|%y|%m|%s|%l\n' >> "$tmp"
  fi
done

while IFS= read -r line; do
  path=${line%%|*}
  rest=${line#*|}
  rel=${path#"$root"/}
  printf '%s|%s\n' "$rel" "$rest"
done < "$tmp" | LC_ALL=C sort > "$out"

rm -f "$tmp"
