#!/bin/sh
# Wrapper: load gxd defaults, then exec with exported env.

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/config.defaults.sh"

exec env "$@"
