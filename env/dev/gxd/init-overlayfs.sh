#!/bin/sh
# Initialize bind mounts and seeded /gnu/store inside a private mount namespace.

set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/config.defaults.sh"

# Re-derive root-relative paths for the selected GXD_DEV_ROOT.
GXD_STORE_UPPER_DIR="${GXD_DEV_ROOT}/gnu/store-upper"
GXD_STORE_WORK_DIR="${GXD_DEV_ROOT}/gnu/store-work"
GXD_STORE_LOWER_DIR="${GXD_DEV_ROOT}/gnu/store-lower"
GXD_STORE_ITEMS_FILE="${GXD_DEV_ROOT}/gnu/store-items.txt"
GXD_VAR_GUIX_DIR="${GXD_DEV_ROOT}/var/guix"
GXD_ETC_GUIX_DIR="${GXD_DEV_ROOT}/etc/guix"
GXD_OVERLAYFS_PID_FILE="${GXD_DEV_ROOT}/overlayfs-container.pid"

resolve_command_path() {
  candidate="$1"

  if [ -x "$candidate" ]; then
    readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
    return 0
  fi

  resolved="$(command -v "$candidate" 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    return 1
  fi

  readlink -f "$resolved" 2>/dev/null || printf '%s\n' "$resolved"
}

TAIL_BIN="$(resolve_command_path tail 2>/dev/null || true)"
if [ -z "$TAIL_BIN" ]; then
  TAIL_BIN="/run/current-system/profile/bin/tail"
  TAIL_BIN="$(readlink -f "$TAIL_BIN" 2>/dev/null || printf '%s\n' "$TAIL_BIN")"
fi

if [ ! -x "$TAIL_BIN" ]; then
  printf 'ERROR: tail binary not executable: %s\n' "$TAIL_BIN" >&2
  exit 1
fi

CURRENT_NS=$(readlink /proc/self/ns/mnt 2>/dev/null || echo "mnt:[unknown]")
INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null || echo "mnt:[unavailable]")

if [ "$INIT_NS" != "mnt:[unavailable]" ] && [ "$CURRENT_NS" = "$INIT_NS" ]; then
  echo "ERROR: This script must run in a private mount namespace." >&2
  exit 1
fi

if [ ! -f "$GXD_STORE_ITEMS_FILE" ]; then
  printf 'ERROR: store items file missing: %s\n' "$GXD_STORE_ITEMS_FILE" >&2
  exit 1
fi

echo "Initializing seeded /gnu/store in mount namespace $CURRENT_NS..."

mkdir -p "${GXD_STORE_LOWER_DIR}" "${GXD_STORE_UPPER_DIR}" "${GXD_STORE_WORK_DIR}"

# Keep mounts local to this namespace.
mount --make-rprivate /

# Bind dev-root paths into canonical Guix locations.
mount --bind "$GXD_VAR_GUIX_DIR/gc.lock" /var/guix/gc.lock
mount --bind "$GXD_VAR_GUIX_DIR/daemon-socket" /var/guix/daemon-socket
mount --bind "$GXD_VAR_GUIX_DIR/db" /var/guix/db
mount --bind "$GXD_VAR_GUIX_DIR/discover" /var/guix/discover
mount --bind "$GXD_VAR_GUIX_DIR/gcroots" /var/guix/gcroots
mount --bind "$GXD_VAR_GUIX_DIR/offload" /var/guix/offload
mount --bind "$GXD_VAR_GUIX_DIR/substitute" /var/guix/substitute
mount --bind "$GXD_VAR_GUIX_DIR/temproots" /var/guix/temproots
mount --bind "$GXD_VAR_GUIX_DIR/profiles/per-user" /var/guix/profiles/per-user
mount --bind "${GXD_DEV_ROOT}/var/log/guix" /var/log/guix
mount --bind "$GXD_ETC_GUIX_DIR" /etc/guix

# Bind host /gnu/store to lower dir, then expose writable seeded store at /gnu/store.
mount --bind /gnu/store "$GXD_STORE_LOWER_DIR"
mount --bind "$GXD_STORE_UPPER_DIR" /gnu/store

chown "$GXD_DAEMON_USER:$GXD_DAEMON_GROUP" /gnu/store 2>/dev/null || true
chmod 1775 /gnu/store 2>/dev/null || true

# Hold this namespace alive for later nsenter calls.
"$TAIL_BIN" -f /dev/null >/dev/null 2>&1 &
PID=$!

PID_FILE="${GXD_OVERLAYFS_PID_FILE}"
printf '%s\n' "$PID" > "$PID_FILE"
chmod 0644 "$PID_FILE" 2>/dev/null || true

echo "Container init session PID: $PID (saved to $PID_FILE)"
