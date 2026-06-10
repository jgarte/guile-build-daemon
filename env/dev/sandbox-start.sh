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

# populate root
mkdir -p "$SANDBOX_ROOT" && cd "$SANDBOX_ROOT"
mkdir --parents \
      gnu/store \
      etc/guix \
      dev

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

# Populate sandbox store with hard-linked requisites.
# This mirrors what 'guix shell --container --share=/gnu/store=...' does.
SEED_STORE_ITEMS=$(guix build coreutils guix shadow psmisc bash)
for store_item in $(guix gc --requisites $SEED_STORE_ITEMS); do
    item_name=$(basename "$store_item")
    if [ ! -e "./gnu/store/$item_name" ]; then
        cp -al "$store_item" ./gnu/store/
    fi
done

# Create FIFO file to block until sandbox reports its namespace PID.
mkfifo ./dev/sandbox-internal.pid

export SANDBOX_ROOT
unshare --fork --user --map-root-user /bin/sh -eu -c '
  unshare --fork --mount /bin/sh -eu -c "
    mount --make-rprivate /
    mount --bind \"$SANDBOX_ROOT/gnu/store\" /gnu/store
    mount --bind \"$SANDBOX_ROOT/etc/guix\" /etc/guix
    echo \"\$\$\" > \"$SANDBOX_ROOT/dev/sandbox-internal.pid\"
    exec sleep infinity
  "
' &

SANDBOX_PID=$!
echo "$SANDBOX_PID" > ./dev/sandbox.pid

# waits for the FIFO file to get written (avoid racing)
SANDBOX_NS_PID=$(cat ./dev/sandbox-internal.pid)
rm -f ./dev/sandbox-internal.pid
echo "$SANDBOX_NS_PID" > ./dev/sandbox-ns.pid

SANDBOX_NS_SETTER_PID=$(ps -o ppid= -p "$SANDBOX_NS_PID" | tr -d ' ')
echo "$SANDBOX_NS_SETTER_PID" > ./dev/sandbox-ns-setter.pid

# Report to user (stderr)
echo "Sandbox started:" 1>&2
echo "  - Shared dirs are bind mounted to: $SANDBOX_ROOT" 1>&2
echo "  - Sandbox PID:                     $SANDBOX_PID" 1>&2
echo "  - Sandbox PID that sets namespace: $SANDBOX_NS_SETTER_PID" 1>&2
echo "  - Sandbox's namespace PID:         $SANDBOX_NS_PID" 1>&2

# return pid to id the namespace
echo "$SANDBOX_NS_PID"
