#!/bin/sh
# starts a simple sandbox namespace in the background
# returns PID for namespace to 'nsenter' into later

set -eu

# Use root dir from the argument or make a new tmp dir
if [ -n "${1:-}" ]; then
    SANDBOX_ROOT="$1"
else
    SANDBOX_ROOT=$(mktemp -d /tmp/guix-container-shares-XXXXXX)
fi

# populate fake root
mkdir -p "$SANDBOX_ROOT" && cd "$SANDBOX_ROOT"
mkdir --parents \
      bin \
      dev \
      etc/guix \
      gnu/store \
      proc \
      run \
      tmp
chmod 1777 ./tmp

# add Access-Control Lists for substitutes validation
cat << 'EOF' > ./etc/guix/acl
(acl
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
)
EOF

# use currently active host guix + guix-daemon (e.g. from guix pull),
# not packaged defaults from channels.
HOST_GUIX_PATH=$(readlink -f "$(command -v guix)")
case "$HOST_GUIX_PATH" in
    /gnu/store/*/bin/guix)
        HOST_GUIX_STORE_ITEM=$(dirname "$(dirname "$HOST_GUIX_PATH")")
        HOST_GUIX_EXEC_IN_SANDBOX="/gnu/store/$(basename "$HOST_GUIX_STORE_ITEM")/bin/guix"
        ;;
    /gnu/store/*)
        HOST_GUIX_STORE_ITEM="$HOST_GUIX_PATH"
        HOST_GUIX_EXEC_IN_SANDBOX="/gnu/store/$(basename "$HOST_GUIX_STORE_ITEM")"
        ;;
    *)
        echo "error: 'guix' does not resolve to a /gnu/store path: $HOST_GUIX_PATH" 1>&2
        exit 1
        ;;
esac

if ! command -v guix-daemon >/dev/null 2>&1; then
    echo "error: 'guix-daemon' not found on host PATH" 1>&2
    exit 1
fi

HOST_GUIX_DAEMON_PATH=$(readlink -f "$(command -v guix-daemon)")
case "$HOST_GUIX_DAEMON_PATH" in
    /gnu/store/*/bin/guix-daemon)
        HOST_GUIX_DAEMON_STORE_ITEM=$(dirname "$(dirname "$HOST_GUIX_DAEMON_PATH")")
        HOST_GUIX_DAEMON_EXEC_IN_SANDBOX="/gnu/store/$(basename "$HOST_GUIX_DAEMON_STORE_ITEM")/bin/guix-daemon"
        ;;
    /gnu/store/*)
        HOST_GUIX_DAEMON_STORE_ITEM="$HOST_GUIX_DAEMON_PATH"
        HOST_GUIX_DAEMON_EXEC_IN_SANDBOX="/gnu/store/$(basename "$HOST_GUIX_DAEMON_STORE_ITEM")"
        ;;
    *)
        echo "error: 'guix-daemon' does not resolve to a /gnu/store path: $HOST_GUIX_DAEMON_PATH" 1>&2
        exit 1
        ;;
esac

# build baseline profile (similar to guix shell --link-profile)
guix package --profile=./profile --install coreutils shadow psmisc bash >/dev/null

# collect closure and mount only these store items read-only
guix gc --requisites \
    ./profile \
    "$HOST_GUIX_STORE_ITEM" \
    "$HOST_GUIX_DAEMON_STORE_ITEM" > ./store-requisites.list

# build a merged profile view that includes host-current guix and guix-daemon
mkdir -p ./profile-merged/bin ./profile-merged/sbin ./profile-merged/etc
for entry in ./profile/bin/*; do
    [ -e "$entry" ] || continue
    ln -sf "/profile/bin/$(basename "$entry")" "./profile-merged/bin/$(basename "$entry")"
done
if [ -d ./profile/sbin ]; then
    for entry in ./profile/sbin/*; do
        [ -e "$entry" ] || continue
        ln -sf "/profile/sbin/$(basename "$entry")" "./profile-merged/sbin/$(basename "$entry")"
    done
fi
ln -sf /profile/etc/profile ./profile-merged/etc/profile
ln -sf "$HOST_GUIX_EXEC_IN_SANDBOX" ./profile-merged/bin/guix
ln -sf "$HOST_GUIX_DAEMON_EXEC_IN_SANDBOX" ./profile-merged/bin/guix-daemon

# shell entrypoints resolve via merged profile
ln -sf /profile-merged/bin/sh ./bin/sh
ln -sf /profile-merged/bin/bash ./bin/bash
ln -sf /profile-merged/bin/guix ./bin/guix
ln -sf /profile-merged/bin/guix-daemon ./bin/guix-daemon

# Create FIFO file to block until sandbox reports its namespace PID.
mkfifo ./sandbox-internal.pid

export SANDBOX_ROOT
unshare --user --map-root-user /bin/sh -eu -c '
  exec unshare --mount /bin/sh -eu -c "
    mount --make-rprivate /
    mount --bind \"$SANDBOX_ROOT\" \"$SANDBOX_ROOT\"

    # mount only profile closure into fake /gnu/store (read-only)
    while IFS= read -r store_item; do
      item_name=\$(basename \"\$store_item\")
      target=\"$SANDBOX_ROOT/gnu/store/\$item_name\"
      if [ -e \"\$target\" ]; then
        continue
      fi
      if [ -d \"\$store_item\" ]; then
        mkdir -p \"\$target\"
      else
        : > \"\$target\"
      fi
      mount --bind \"\$store_item\" \"\$target\"
      mount -o remount,bind,ro \"\$target\"
    done < \"$SANDBOX_ROOT/store-requisites.list\"

    # minimal Linux API FS for guix userland
    mount --rbind /dev \"$SANDBOX_ROOT/dev\"
    mount --rbind /proc \"$SANDBOX_ROOT/proc\"
    mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs \"$SANDBOX_ROOT/tmp\"

    # pivot to fake root
    cd \"$SANDBOX_ROOT\"
    mkdir -p .old-root
    pivot_root . .old-root

    export GUIX_PROFILE=/profile-merged
    if [ -f /profile-merged/etc/profile ]; then
      . /profile-merged/etc/profile
    fi
    export PATH=/bin:/profile-merged/bin:/profile-merged/sbin:/profile/bin:/profile/sbin

    echo \"\$\$\" > /sandbox-internal.pid
    exec sleep infinity
  "
' &

SANDBOX_PID=$!
echo "$SANDBOX_PID" > ./dev/sandbox.pid

# waits for the FIFO file to get written (avoid racing)
SANDBOX_NS_PID=$(cat ./sandbox-internal.pid)
rm -f ./sandbox-internal.pid
echo "$SANDBOX_NS_PID" > ./dev/sandbox-ns.pid

# Report to user (stderr)
echo "Sandbox started:" 1>&2
echo "  - Fake root:                       $SANDBOX_ROOT" 1>&2
echo "  - Profile:                         $SANDBOX_ROOT/profile" 1>&2
echo "  - Merged profile:                  $SANDBOX_ROOT/profile-merged" 1>&2
echo "  - Guix binaries:                   /profile-merged/bin/guix{,-daemon}" 1>&2
echo "  - /gnu/store binds:                guix gc --requisites (read-only)" 1>&2
echo "  - Sandbox PID:                     $SANDBOX_PID" 1>&2
echo "  - Sandbox's namespace PID:         $SANDBOX_NS_PID" 1>&2

# return pid to id the namespace
echo "$SANDBOX_NS_PID"
