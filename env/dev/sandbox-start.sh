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

echo "Working dir: $(pwd)"

# populate fake root
# /home/user/.config/guix/current must be a symlink to a store profile.
# If "current" is made as a directory, guix gc rejects it as non-store path.
mkdir -p "$SANDBOX_ROOT/home/user/.config/guix"
GUIX_PINNED_STORE=$(readlink -f "$(guix time-machine --channels=env/guix/channels.scm)")
rm -rf "$SANDBOX_ROOT/home/user/.config/guix/current"
ln -s "$GUIX_PINNED_STORE" \
   "$SANDBOX_ROOT/home/user/.config/guix/current"

cd "$SANDBOX_ROOT"
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

# use pinned Guix + guix-daemon from the time-machine profile.

GUIX_PINNED="./home/user/.config/guix/current"
GUIX_PROFILE="./home/user/.guix-profile"

# build baseline profile (similar to guix shell --link-profile)
guix package --profile="$GUIX_PROFILE" --install coreutils shadow psmisc bash >/dev/null

# collect closure and mount only these store items read-only
guix gc --requisites \
    "$GUIX_PROFILE" \
    "$GUIX_PINNED" \
    > ./store-requisites.list

# shell entrypoints
ln -sf "$GUIX_PROFILE/bin/sh" ./bin/sh
ln -sf "$GUIX_PROFILE/bin/bash" ./bin/bash

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

    # clean up the PATH
    export PATH=/bin

    export GUIX_PROFILE=/home/user/.config/guix/current
    . "\$GUIX_PROFILE/etc/profile"
    
    export GUIX_PROFILE=/home/user/.guix-profile
    . "\$GUIX_PROFILE/etc/profile"

    SANDBOX_TERM=\${TERM:-xterm-256color}
    
    echo \"\$\$\" > /sandbox-internal.pid
    exec /profile/bin/env -i \
      HOME=/home/user \
      USER=user \
      LOGNAME=user \
      SHELL=/bin/bash \
      TERM=\"\$SANDBOX_TERM\" \
      PATH=\"\$PATH\" \
      GUIX_PROFILE=\"\$GUIX_PROFILE\" \
      /profile/bin/sleep infinity
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
echo "  - Sandbox PID:                     $SANDBOX_PID" 1>&2
echo "  - Sandbox's namespace PID:         $SANDBOX_NS_PID" 1>&2

# return pid to id the namespace
echo "$SANDBOX_NS_PID"
