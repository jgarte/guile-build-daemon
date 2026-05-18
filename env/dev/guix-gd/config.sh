#!/bin/sh

set -eu

USER_NAME="${USER:-user}"

# Core paths.
: "${GUIX_GD_ROOT:=/tmp/guix-gd-root-${USER_NAME}}"
: "${GUIX_GD_CONTAINER_ROOT:=/tmp/guix-gd-container-${USER_NAME}}"
: "${GUIX_GD_DEV_ROOT:=/tmp/guix-gd-overlayfs-${USER_NAME}}"

# Overlayfs layout.
: "${GUIX_GD_STORE_UPPER_DIR:=${GUIX_GD_DEV_ROOT}/gnu/store-upper}"
: "${GUIX_GD_STORE_WORK_DIR:=${GUIX_GD_DEV_ROOT}/gnu/store-work}"
: "${GUIX_GD_STORE_LOWER_DIR:=${GUIX_GD_DEV_ROOT}/gnu/store-lower}"
: "${GUIX_GD_VAR_GUIX_DIR:=${GUIX_GD_DEV_ROOT}/var/guix}"
: "${GUIX_GD_ETC_GUIX_DIR:=${GUIX_GD_DEV_ROOT}/etc/guix}"
: "${GUIX_GD_OVERLAYFS_PID_FILE:=${GUIX_GD_DEV_ROOT}/overlayfs-container.pid}"

# Users and groups.
: "${GUIX_GD_GROUP:=guix-gd-build}"
: "${GUIX_GD_USER:=guix-gd-daemon}"
: "${GUIX_GD_DAEMON_USER:=root}"
: "${GUIX_GD_DAEMON_GROUP:=root}"
: "${GUIX_GD_CLIENT_USER:=${USER_NAME}}"

# Daemon runtime.
: "${GUIX_GD_DAEMON_BIN:=guix-daemon}"
: "${GUIX_GD_DAEMON_ARGS:=--disable-chroot --disable-deduplication}"
: "${GUIX_GD_DEV_SOCK:=/tmp/guix-gd-fallback-${USER_NAME}.sock}"

# Differential test defaults.
: "${GUIX_GD_TEST_COMMAND:=guix gc --list-roots}"
: "${GUIX_GD_TEST_ARTIFACTS_DIR:=tmp/daemon-differential}"
: "${GUIX_GD_TEST_EXPECT_EXIT:=0}"

: "${GUIX_GD_TEST_REGULAR_ROOT:=/tmp/guix-gd-overlayfs-regular-${USER_NAME}}"
: "${GUIX_GD_TEST_REGULAR_CONTAINER_PID:=}"
: "${GUIX_GD_TEST_REGULAR_SOCKET:=/tmp/guix-gd-fallback-regular-${USER_NAME}.sock}"

: "${GUIX_GD_TEST_RELAY_ROOT:=/tmp/guix-gd-overlayfs-relay-${USER_NAME}}"
: "${GUIX_GD_TEST_RELAY_CONTAINER_PID:=}"
: "${GUIX_GD_TEST_RELAY_SOCKET:=/var/guix/daemon-socket/socket}"
: "${GUIX_GD_TEST_RELAY_SOCKET_HOST:=${GUIX_GD_TEST_RELAY_ROOT}/var/guix/daemon-socket/socket}"
: "${GUIX_GD_TEST_RELAY_FALLBACK_SOCKET:=/tmp/guix-gd-fallback-relay-${USER_NAME}.sock}"

export GUIX_GD_ROOT
export GUIX_GD_CONTAINER_ROOT
export GUIX_GD_DEV_ROOT
export GUIX_GD_STORE_UPPER_DIR
export GUIX_GD_STORE_WORK_DIR
export GUIX_GD_STORE_LOWER_DIR
export GUIX_GD_VAR_GUIX_DIR
export GUIX_GD_ETC_GUIX_DIR
export GUIX_GD_OVERLAYFS_PID_FILE
export GUIX_GD_GROUP
export GUIX_GD_USER
export GUIX_GD_DAEMON_USER
export GUIX_GD_DAEMON_GROUP
export GUIX_GD_CLIENT_USER
export GUIX_GD_DAEMON_BIN
export GUIX_GD_DAEMON_ARGS
export GUIX_GD_DEV_SOCK
export GUIX_GD_TEST_COMMAND
export GUIX_GD_TEST_ARTIFACTS_DIR
export GUIX_GD_TEST_EXPECT_EXIT
export GUIX_GD_TEST_REGULAR_ROOT
export GUIX_GD_TEST_REGULAR_CONTAINER_PID
export GUIX_GD_TEST_REGULAR_SOCKET
export GUIX_GD_TEST_RELAY_ROOT
export GUIX_GD_TEST_RELAY_CONTAINER_PID
export GUIX_GD_TEST_RELAY_SOCKET
export GUIX_GD_TEST_RELAY_SOCKET_HOST
export GUIX_GD_TEST_RELAY_FALLBACK_SOCKET

exec env "$@"
