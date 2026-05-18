#!/bin/sh

set -eu

USER_NAME=${USER:-user}


GUIX_GD_ROOT="/tmp/guix-gd-root-${USER_NAME}"
export GUIX_GD_ROOT

GUIX_GD_CONTAINER_ROOT="/tmp/guix-gd-container-${USER_NAME}"
export GUIX_GD_CONTAINER_ROOT

GUIX_GD_GROUP="guix-gd-build"
export GUIX_GD_GROUP

GUIX_GD_USER="guix-gd-daemon"
export GUIX_GD_USER

GUIX_GD_DEV_SOCK="/tmp/guix-gd-fallback-${USER_NAME}.sock"
export GUIX_GD_DEV_SOCK

GUIX_GD_DEV_ROOT="/tmp/guix-gd-overlayfs-${USER_NAME}"
export GUIX_GD_DEV_ROOT

GUIX_GD_DAEMON_USER="root"
export GUIX_GD_DAEMON_USER

GUIX_GD_DAEMON_GROUP="root"
export GUIX_GD_DAEMON_GROUP

GUIX_GD_CLIENT_USER="${USER_NAME}"
export GUIX_GD_CLIENT_USER

exec env "$@"
