#!/bin/sh
# Source this file to set and export gxd defaults.

_gxd_user_name="${USER:-user}"

# Core paths.
: "${GXD_ROOT:=/tmp/gxd-root-${_gxd_user_name}}"
: "${GXD_CONTAINER_ROOT:=/tmp/gxd-container-${_gxd_user_name}}"
: "${GXD_DEV_ROOT:=/tmp/gxd-overlayfs-${_gxd_user_name}}"

# Container store layout.
: "${GXD_STORE_UPPER_DIR:=${GXD_DEV_ROOT}/gnu/store-upper}"
: "${GXD_STORE_WORK_DIR:=${GXD_DEV_ROOT}/gnu/store-work}"
: "${GXD_STORE_LOWER_DIR:=${GXD_DEV_ROOT}/gnu/store-lower}"
: "${GXD_STORE_ITEMS_FILE:=${GXD_DEV_ROOT}/gnu/store-items.txt}"
: "${GXD_RUNTIME_COMMANDS:=/bin/sh guix guix-daemon tail /run/current-system/profile/bin/guix /run/current-system/profile/bin/guix-daemon /run/current-system/profile/bin/tail}"
: "${GXD_VAR_GUIX_DIR:=${GXD_DEV_ROOT}/var/guix}"
: "${GXD_ETC_GUIX_DIR:=${GXD_DEV_ROOT}/etc/guix}"
: "${GXD_OVERLAYFS_PID_FILE:=${GXD_DEV_ROOT}/overlayfs-container.pid}"

# Users and groups.
: "${GXD_GROUP:=gxd-build}"
: "${GXD_USER:=gxd}"
: "${GXD_DAEMON_USER:=root}"
: "${GXD_DAEMON_GROUP:=root}"
: "${GXD_CLIENT_USER:=${_gxd_user_name}}"

# Daemon runtime.
: "${GXD_DAEMON_BIN:=guix-daemon}"
: "${GXD_DAEMON_ARGS:=--disable-chroot --disable-deduplication}"
: "${GXD_DEV_SOCK:=/tmp/gxd-fallback-${_gxd_user_name}.sock}"

# Differential test defaults.
: "${GXD_TEST_COMMAND:=guix gc --list-roots}"
: "${GXD_TEST_ARTIFACTS_DIR:=tmp/daemon-differential}"
: "${GXD_TEST_EXPECT_EXIT:=0}"

: "${GXD_TEST_REGULAR_ROOT:=/tmp/gxd-overlayfs-regular-${_gxd_user_name}}"
: "${GXD_TEST_REGULAR_CONTAINER_PID:=}"
: "${GXD_TEST_REGULAR_SOCKET:=/tmp/gxd-fallback-regular-${_gxd_user_name}.sock}"

: "${GXD_TEST_RELAY_ROOT:=/tmp/gxd-overlayfs-relay-${_gxd_user_name}}"
: "${GXD_TEST_RELAY_CONTAINER_PID:=}"
: "${GXD_TEST_RELAY_SOCKET:=/var/guix/daemon-socket/socket}"
: "${GXD_TEST_RELAY_SOCKET_HOST:=${GXD_TEST_RELAY_ROOT}/var/guix/daemon-socket/socket}"
: "${GXD_TEST_RELAY_FALLBACK_SOCKET:=/tmp/gxd-fallback-relay-${_gxd_user_name}.sock}"

export GXD_ROOT
export GXD_CONTAINER_ROOT
export GXD_DEV_ROOT
export GXD_STORE_UPPER_DIR
export GXD_STORE_WORK_DIR
export GXD_STORE_LOWER_DIR
export GXD_STORE_ITEMS_FILE
export GXD_RUNTIME_COMMANDS
export GXD_VAR_GUIX_DIR
export GXD_ETC_GUIX_DIR
export GXD_OVERLAYFS_PID_FILE
export GXD_GROUP
export GXD_USER
export GXD_DAEMON_USER
export GXD_DAEMON_GROUP
export GXD_CLIENT_USER
export GXD_DAEMON_BIN
export GXD_DAEMON_ARGS
export GXD_DEV_SOCK
export GXD_TEST_COMMAND
export GXD_TEST_ARTIFACTS_DIR
export GXD_TEST_EXPECT_EXIT
export GXD_TEST_REGULAR_ROOT
export GXD_TEST_REGULAR_CONTAINER_PID
export GXD_TEST_REGULAR_SOCKET
export GXD_TEST_RELAY_ROOT
export GXD_TEST_RELAY_CONTAINER_PID
export GXD_TEST_RELAY_SOCKET
export GXD_TEST_RELAY_SOCKET_HOST
export GXD_TEST_RELAY_FALLBACK_SOCKET

unset _gxd_user_name
