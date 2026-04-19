# turn Bash into a "fail-fast" environment to prevent silent failures:
set -o errexit     # -e: Exit immediately if a command exits with a non-zero status
set -o nounset     # -u: Treat unset variables as an error and exit immediately
set -o pipefail    #      Return status of the last command in the pipe that failed

# NOTE: this script is meant to be run from new mount namespace!

# Compare current process mount namespace to the init process (PID 1)
CURRENT_NS=$(readlink /proc/self/ns/mnt)
INIT_NS=$(readlink /proc/1/ns/mnt)

if [ "$CURRENT_NS" == "$INIT_NS" ]; then
    echo "ERROR: This script must be run within a private mount namespace." >&2
    exit 1
fi

echo "Initializing /gnu/guix overlayfs in mount namespace $CURRENT_NS..."

# Prevent mount propagation back to host namespace.
mount --make-rprivate /

mount --bind "$GUIX_GD_VAR_GUIX_DIR" /var/guix
mount --bind "$GUIX_GD_ETC_GUIX_DIR" /etc/guix

# Keep host store available as overlay lowerdir, then replace /gnu/store with a writable overlay whose upper/work dirs are local.
# Overlayfs requires that the ~lowerdir~ and the overlay mount point (~/gnu/store~) are *not* the same directory.
mkdir -p /run/guix-gd-host-store
mount --bind /gnu/store /run/guix-gd-host-store
mount -t overlay overlay \
      -o "lowerdir=/run/guix-gd-host-store,upperdir=$GUIX_GD_STORE_UPPER_DIR,workdir=$GUIX_GD_STORE_WORK_DIR" \
      /gnu/store

# Make merged store writable for daemon user (metadata copy-up only).
chown "$GUIX_GD_DAEMON_USER:$GUIX_GD_DAEMON_GROUP" /gnu/store || true
chmod 1775 /gnu/store || true

setsid sh -c 'exec tail -f /dev/null' >/dev/null 2>&1 &


