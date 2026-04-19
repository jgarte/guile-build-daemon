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
# --make-rprivate: recursively mark `/` as private so mounts created here are not propagated back to the original (host) mount namespace.
mount --make-rprivate /

# Bind the per-dev-root guix dirs into the namespace's expected locations.
# --bind: perform a bind mount (make the same directory appear at a different location).
mount --bind "$GUIX_GD_VAR_GUIX_DIR" /var/guix
mount --bind "$GUIX_GD_ETC_GUIX_DIR" /etc/guix

# Keep host store available as overlay lowerdir, then replace /gnu/store with a writable overlay whose upper/work dirs are local.
# Overlayfs requires that the lowerdir and the overlay mount point (/gnu/store) are NOT the same directory.
mkdir --parents /run/guix-gd-host-store
mount --bind /gnu/store /run/guix-gd-host-store
# Use long-form options for clarity: --types and --options
mount --types overlay overlay \
      --options "lowerdir=/run/guix-gd-host-store,upperdir=$GUIX_GD_STORE_UPPER_DIR,workdir=$GUIX_GD_STORE_WORK_DIR" \
      /gnu/store

# Make merged store writable for daemon user (metadata copy-up only).
chown "$GUIX_GD_DAEMON_USER:$GUIX_GD_DAEMON_GROUP" /gnu/store || true
chmod 1775 /gnu/store || true

# Start a background session leader to hold the mount namespace alive.
# Explanation:
# - `setsid` runs the command in a new session so the process becomes a session leader and detaches from the controlling terminal.
# - `nohup` makes the process ignore SIGHUP (prevents termination if the parent/controlling terminal disappears).
# - `sh -c 'exec ...'` ensures the PID of the process created by `setsid` is the PID of the final program (we use `exec` so the shell is replaced by the program).
# - We deliberately do NOT use `setsid --fork` (or `-f`) because that causes `setsid` to fork and return; then `$!` would not reliably refer to the final daemon PID.
# - Redirect stdout/stderr to /dev/null to avoid creating `nohup.out` and to keep the process silent.
setsid sh -c 'exec nohup tail -f /dev/null >/dev/null 2>&1' >/dev/null 2>&1 &
PID=$!

# Save PID to a known location so external tools can nsenter into this mount namespace later.
# Prefer the provided GUIX_GD_VAR_GUIX_DIR; fall back to /run if not set.
PID_FILE="${GUIX_GD_VAR_GUIX_DIR:-/run}/guix-gd-overlayfs.pid"
printf '%s\n' "$PID" > "$PID_FILE"
chmod 0644 "$PID_FILE"
echo "OverlayFS init session PID: $PID (saved to $PID_FILE)"


