#!/bin/sh
# Recreate artifacts directory from scratch.

set -eu

HOST_PATH="${GUIX_GD_HOST_PATH:-/run/setuid-programs:/run/current-system/profile/bin:/run/current-system/profile/sbin:/bin:/usr/bin:/usr/sbin}"
PATH="$HOST_PATH"
export PATH

dir="$1"
rm -rf "$dir"
mkdir -p "$dir"
