#!/usr/bin/env bash
# turn Bash into a "fail-fast" environment to prevent silent failures:
set -o errexit     # -e: Exit immediately if a command exits with a non-zero status
set -o nounset     # -u: Treat unset variables as an error and exit immediately
set -o pipefail    #      Return status of the last command in the pipe that failed

# Set some defaults to script will run regardless current env:
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT:-${SCRIPT_DIR}/.dev-root}"
GUIX_GD_STORE_UPPER_DIR="${GUIX_GD_STORE_UPPER_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-upper}"
GUIX_GD_STORE_WORK_DIR="${GUIX_GD_STORE_WORK_DIR:-${GUIX_GD_DEV_ROOT}/gnu/store-work}"
GUIX_GD_VAR_GUIX_DIR="${GUIX_GD_VAR_GUIX_DIR:-${GUIX_GD_DEV_ROOT}/var/guix}"
GUIX_GD_ETC_GUIX_DIR="${GUIX_GD_ETC_GUIX_DIR:-${GUIX_GD_DEV_ROOT}/etc/guix}"
GUIX_GD_DAEMON_USER="${GUIX_GD_DAEMON_USER:-root}"
GUIX_GD_DAEMON_GROUP="${GUIX_GD_DAEMON_GROUP:-root}"
GUIX_GD_GROUP="${GUIX_GD_DAEMON_GROUP:-guix-gd-build}"
GUIX_GD_DAEMON_BIN="${GUIX_GD_DAEMON_BIN:-guix-daemon}"

# Ensure directories exist.
mkdir -p \
      "${GUIX_GD_STORE_UPPER_DIR}" \
      "${GUIX_GD_STORE_WORK_DIR}" \
      "${GUIX_GD_VAR_GUIX_DIR}" \
      "${GUIX_GD_ETC_GUIX_DIR}"

# Ensure mount points exist in the host FS namespace.
# mkdir -p /gnu/store /var/guix /etc/guix

# workdir is for overlayfs internals; keep it root-owned.
chown root:root "${GUIX_GD_STORE_WORK_DIR}"
chmod 0700 "${GUIX_GD_STORE_WORK_DIR}"

# Set dirs ownership for daemon.
chown -R "${GUIX_GD_DAEMON_USER}:${GUIX_GD_DAEMON_GROUP}" \
      "${GUIX_GD_STORE_UPPER_DIR}" "${GUIX_GD_VAR_GUIX_DIR}" "${GUIX_GD_ETC_GUIX_DIR}"

echo "== guix-gd /gnu/store overlay =="
echo "daemon user:  ${GUIX_GD_DAEMON_USER}"
echo "daemon group:  ${GUIX_GD_DAEMON_GROUP}"
echo "daemon bin:   ${GUIX_GD_DAEMON_BIN}"
echo "/gnu/store -> overlay(lower=/gnu/store, upper=${GUIX_GD_STORE_UPPER_DIR})"
echo "/var/guix -> ${GUIX_GD_VAR_GUIX_DIR}"
echo "/etc/guix -> ${GUIX_GD_ETC_GUIX_DIR}"
echo

printf "Start dev guix-daemon in overlayFS for /gnu/store? [y/N]: "
read -r CONFIRM

case "$CONFIRM" in
    [yY][eE][sS]|[yY])
        # Run in a private mount namespace so remaps disappear automatically when
        # daemon exits.
        exec unshare --mount --fork -- env \
             GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT}"
             GUIX_GD_STORE_UPPER_DIR="${GUIX_GD_STORE_UPPER_DIR}" \
             GUIX_GD_STORE_WORK_DIR="${GUIX_GD_STORE_WORK_DIR}" \
             GUIX_GD_VAR_GUIX_DIR="${GUIX_GD_VAR_GUIX_DIR}" \
             GUIX_GD_ETC_GUIX_DIR="${GUIX_GD_ETC_GUIX_DIR}" \
             GUIX_GD_DAEMON_USER="${GUIX_GD_DAEMON_USER}" \
             GUIX_GD_DAEMON_GROUP="${GUIX_GD_DAEMON_GROUP}" \
             GUIX_GD_DAEMON_BIN="${GUIX_GD_DAEMON_BIN}" \
             GUIX_GD_GROUP="${GUIX_GD_DAEMON_GROUP}" \
             bash ${SCRIPT_DIR}/init-overlayfs.sh
        ;;
    *)
        echo "Aborting."
        exit 1
        ;;
esac
