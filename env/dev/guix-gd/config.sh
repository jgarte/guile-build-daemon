#!/bin/sh
# Print environment variable assignments for dev guix-daemon.
# When used inside a shell substitution `$(./config.sh)` this prints
# `VAR=val VAR2=val2 ...` which can be passed to `env`.

set -eu

USER_NAME=${USER:-user}

GUIX_GD_ROOT="/tmp/guix-gd-root-${USER_NAME}"
GUIX_GD_CONTAINER_ROOT="/tmp/guix-gd-container-${USER_NAME}"
GUIX_GD_GROUP="guix-gd-build"
GUIX_GD_USER="guix-gd-daemon"
GUIX_GD_DEV_SOCK="/tmp/guix-gd-fallback-${USER_NAME}.sock"
GUIX_GD_DEV_ROOT="/tmp/guix-gd-overlayfs-${USER_NAME}"
GUIX_GD_DAEMON_USER="root"
GUIX_GD_DAEMON_GROUP="root"
GUIX_GD_CLIENT_USER="${USER_NAME}"

if [ "$#" -eq 0 ]; then
  # Print as a single line of assignments suitable for `env $(./config.sh)`
  printf '%s %s %s %s %s %s %s %s %s' \
    "GUIX_GD_ROOT=${GUIX_GD_ROOT}" \
    "GUIX_GD_CONTAINER_ROOT=${GUIX_GD_CONTAINER_ROOT}" \
    "GUIX_GD_GROUP=${GUIX_GD_GROUP}" \
    "GUIX_GD_USER=${GUIX_GD_USER}" \
    "GUIX_GD_DEV_SOCK=${GUIX_GD_DEV_SOCK}" \
    "GUIX_GD_DEV_ROOT=${GUIX_GD_DEV_ROOT}" \
    "GUIX_GD_DAEMON_USER=${GUIX_GD_DAEMON_USER}" \
    "GUIX_GD_DAEMON_GROUP=${GUIX_GD_DAEMON_GROUP}" \
    "GUIX_GD_CLIENT_USER=${GUIX_GD_CLIENT_USER}"
  exit 0
fi

# Support running a command directly: export variables and exec the command.
export GUIX_GD_ROOT GUIX_GD_CONTAINER_ROOT GUIX_GD_GROUP GUIX_GD_USER \
       GUIX_GD_DEV_SOCK GUIX_GD_DEV_ROOT GUIX_GD_DAEMON_USER GUIX_GD_DAEMON_GROUP GUIX_GD_CLIENT_USER
exec "$@"
