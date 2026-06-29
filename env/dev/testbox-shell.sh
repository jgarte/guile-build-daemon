#!/bin/sh
set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 PID [COMMAND ARG...]" 1>&2
    exit 2
fi

target=$1
shift

if [ "$#" -eq 0 ]; then
    set -- bash --login
fi

exec nsenter --target "$target" \
             --preserve-credentials \
             --user \
             --env \
             --mount \
             "$@"
