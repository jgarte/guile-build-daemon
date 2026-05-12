#!/bin/sh
# Initialize bind mounts and overlayfs inside a private mount namespace.

set -eu
set -o pipefail 2>/dev/null || true

GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT:-/tmp/guix-gd-overlayfs-${USER:-user}}"
GUIX_GD_STORE_UPPER_DIR="${GUIX_GD_STORE_UPPER_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-upper}"
GUIX_GD_STORE_WORK_DIR="${GUIX_GD_STORE_WORK_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-work}"
GUIX_GD_STORE_LOWER_DIR="${GUIX_GD_STORE_LOWER_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-lower}"
GUIX_GD_VAR_GUIX_DIR="${GUIX_GD_VAR_GUIX_DIR:-${GUIX_GD_DEV_ROOT}/var/guix}"
GUIX_GD_ETC_GUIX_DIR="${GUIX_GD_ETC_GUIX_DIR:-${GUIX_GD_DEV_ROOT}/etc/guix}"
GUIX_GD_DAEMON_USER="${GUIX_GD_DAEMON_USER:-root}"
GUIX_GD_DAEMON_GROUP="${GUIX_GD_DAEMON_GROUP:-root}"

CURRENT_NS=$(readlink /proc/self/ns/mnt 2>/dev/null || echo "mnt:[unknown]")
INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null || echo "mnt:[unavailable]")

if [ "$INIT_NS" != "mnt:[unavailable]" ] && [ "$CURRENT_NS" = "$INIT_NS" ]; then
  echo "ERROR: This script must run in a private mount namespace." >&2
  exit 1
fi

echo "Initializing /gnu/store overlayfs in mount namespace $CURRENT_NS..."

mkdir -p "${GUIX_GD_STORE_LOWER_DIR}" "${GUIX_GD_STORE_UPPER_DIR}" "${GUIX_GD_STORE_WORK_DIR}"

# Keep mounts local to this namespace.
mount --make-rprivate /

# Bind dev-root paths into canonical Guix locations.
mount --bind "$GUIX_GD_VAR_GUIX_DIR/gc.lock" /var/guix/gc.lock
mount --bind "$GUIX_GD_VAR_GUIX_DIR/daemon-socket" /var/guix/daemon-socket
mount --bind "$GUIX_GD_VAR_GUIX_DIR/db" /var/guix/db
mount --bind "$GUIX_GD_VAR_GUIX_DIR/discover" /var/guix/discover
mount --bind "$GUIX_GD_VAR_GUIX_DIR/gcroots" /var/guix/gcroots
mount --bind "$GUIX_GD_VAR_GUIX_DIR/offload" /var/guix/offload
mount --bind "$GUIX_GD_VAR_GUIX_DIR/substitute" /var/guix/substitute
mount --bind "$GUIX_GD_VAR_GUIX_DIR/temproots" /var/guix/temproots
mount --bind "${GUIX_GD_DEV_ROOT}/var/log/guix" /var/log/guix
mount --bind "$GUIX_GD_ETC_GUIX_DIR" /etc/guix

# Overlay /gnu/store with writable upper/work dirs under GUIX_GD_DEV_ROOT.
mount --bind /gnu/store "$GUIX_GD_STORE_LOWER_DIR"
mount -t overlay overlay \
  -o "lowerdir=$GUIX_GD_STORE_LOWER_DIR,upperdir=$GUIX_GD_STORE_UPPER_DIR,workdir=$GUIX_GD_STORE_WORK_DIR" \
  /gnu/store

chown "$GUIX_GD_DAEMON_USER:$GUIX_GD_DAEMON_GROUP" /gnu/store 2>/dev/null || true
chmod 1775 /gnu/store 2>/dev/null || true

# Hold this namespace alive for later nsenter calls.
setsid sh -c 'exec nohup tail -f /dev/null >/dev/null 2>&1' >/dev/null 2>&1 &
PID=$!

PID_FILE="${GUIX_GD_DEV_ROOT}/overlayfs-container.pid"
printf '%s\n' "$PID" > "$PID_FILE"
chmod 0644 "$PID_FILE"

echo "OverlayFS init session PID: $PID (saved to $PID_FILE)"
