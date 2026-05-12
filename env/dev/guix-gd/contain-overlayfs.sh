#!/bin/sh
# Configure a rootless overlayfs sandbox for a dev guix-daemon.

set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT:-/tmp/guix-gd-overlayfs-${USER:-user}}"
GUIX_GD_STORE_UPPER_DIR="${GUIX_GD_STORE_UPPER_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-upper}"
GUIX_GD_STORE_WORK_DIR="${GUIX_GD_STORE_WORK_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-work}"
GUIX_GD_STORE_LOWER_DIR="${GUIX_GD_STORE_LOWER_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-lower}"
GUIX_GD_VAR_GUIX_DIR="${GUIX_GD_VAR_GUIX_DIR:-${GUIX_GD_DEV_ROOT}/var/guix}"
GUIX_GD_ETC_GUIX_DIR="${GUIX_GD_ETC_GUIX_DIR:-${GUIX_GD_DEV_ROOT}/etc/guix}"
GUIX_GD_DAEMON_USER="${GUIX_GD_DAEMON_USER:-root}"
GUIX_GD_DAEMON_GROUP="${GUIX_GD_DAEMON_GROUP:-root}"
GUIX_GD_GROUP="${GUIX_GD_GROUP:-guix-gd-build}"
GUIX_GD_DAEMON_BIN="${GUIX_GD_DAEMON_BIN:-guix-daemon}"

if ! command -v unshare >/dev/null 2>&1; then
  printf 'ERROR: unshare not found in PATH.\n' >&2
  exit 1
fi

mkdir -p \
  "${GUIX_GD_STORE_WORK_DIR}" \
  "${GUIX_GD_STORE_UPPER_DIR}" \
  "${GUIX_GD_STORE_LOWER_DIR}" \
  "${GUIX_GD_VAR_GUIX_DIR}/daemon-socket" \
  "${GUIX_GD_VAR_GUIX_DIR}/db" \
  "${GUIX_GD_VAR_GUIX_DIR}/discover" \
  "${GUIX_GD_VAR_GUIX_DIR}/gcroots" \
  "${GUIX_GD_VAR_GUIX_DIR}/offload" \
  "${GUIX_GD_VAR_GUIX_DIR}/substitute" \
  "${GUIX_GD_VAR_GUIX_DIR}/temproots" \
  "${GUIX_GD_DEV_ROOT}/var/log/guix" \
  "${GUIX_GD_ETC_GUIX_DIR}"

touch "${GUIX_GD_VAR_GUIX_DIR}/gc.lock"

if [ -f /etc/guix/acl ]; then
  cp -f /etc/guix/acl "${GUIX_GD_ETC_GUIX_DIR}/acl"
  chmod u+rw "${GUIX_GD_ETC_GUIX_DIR}/acl"
elif [ ! -f "${GUIX_GD_ETC_GUIX_DIR}/acl" ]; then
  printf '%s\n' "(acl
 (entry
  (public-key
   (ecc
    (curve Ed25519)
    (q #8D156F295D24B0D9A86FA5741A840FF2D24F60F7B6C4134814AD55625971B394#)
    )
   )
  (tag
   (guix import)
   )
  )
 (entry
  (public-key
   (ecc
    (curve Ed25519)
    (q #7D602902D3A2DBB83F8A0FB98602A754C5493B0B778C8D1DD4E0F41DE14DE34F#)
    )
   )
  (tag
   (guix import)
   )
  )
 )" > "${GUIX_GD_ETC_GUIX_DIR}/acl"
fi

chmod 0700 "${GUIX_GD_STORE_WORK_DIR}"

for path in \
  /gnu/store \
  /var/guix/gc.lock \
  /var/guix/daemon-socket \
  /var/guix/db \
  /var/guix/discover \
  /var/guix/gcroots \
  /var/guix/offload \
  /var/guix/substitute \
  /var/guix/temproots \
  /var/log/guix \
  /etc/guix

do
  if [ ! -e "$path" ]; then
    printf 'ERROR: required path does not exist: %s\n' "$path" >&2
    exit 1
  fi
done

echo "== guix-gd /gnu/store overlay (rootless) =="
echo "daemon user:   ${GUIX_GD_DAEMON_USER}"
echo "daemon group:  ${GUIX_GD_DAEMON_GROUP}"
echo "daemon bin:    ${GUIX_GD_DAEMON_BIN}"
echo "build group:   ${GUIX_GD_GROUP}"
echo "/gnu/store -> overlay:"
echo "                lower=${GUIX_GD_STORE_LOWER_DIR}"
echo "                upper=${GUIX_GD_STORE_UPPER_DIR}"
echo "                work=${GUIX_GD_STORE_WORK_DIR}"
echo "/var/guix{...} -> ${GUIX_GD_VAR_GUIX_DIR}"
echo "/etc/guix -> ${GUIX_GD_ETC_GUIX_DIR}"
echo "namespace mode: unshare --user --map-root-user + unshare --mount"
echo

printf 'Start rootless dev overlayfs container? [y/N]: '
read -r CONFIRM

case "$CONFIRM" in
  [yY][eE][sS]|[yY])
    exec unshare --user --map-root-user --fork -- env \
      GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT}" \
      GUIX_GD_STORE_UPPER_DIR="${GUIX_GD_STORE_UPPER_DIR}" \
      GUIX_GD_STORE_WORK_DIR="${GUIX_GD_STORE_WORK_DIR}" \
      GUIX_GD_STORE_LOWER_DIR="${GUIX_GD_STORE_LOWER_DIR}" \
      GUIX_GD_VAR_GUIX_DIR="${GUIX_GD_VAR_GUIX_DIR}" \
      GUIX_GD_ETC_GUIX_DIR="${GUIX_GD_ETC_GUIX_DIR}" \
      GUIX_GD_DAEMON_USER="${GUIX_GD_DAEMON_USER}" \
      GUIX_GD_DAEMON_GROUP="${GUIX_GD_DAEMON_GROUP}" \
      GUIX_GD_DAEMON_BIN="${GUIX_GD_DAEMON_BIN}" \
      GUIX_GD_GROUP="${GUIX_GD_GROUP}" \
      /bin/sh -c 'exec unshare --mount --fork -- /bin/sh "$1"' \
      sh "${SCRIPT_DIR}/init-overlayfs.sh"
    ;;
  *)
    echo "Aborting."
    exit 1
    ;;
esac
