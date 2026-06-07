#!/bin/sh
# starts a simple guix container in the background
# retuns PID for namespace to 'nsenter' into later

# Use root dir from the argument or make a new tmp dir
if [ -n "$1" ]; then
    SANDBOX_ROOT="$1"
else
    SANDBOX_ROOT=$(mktemp -d /tmp/guix-container-shares-XXXXXX)
fi

# populate root
mkdir -p "$SANDBOX_ROOT" && cd "$SANDBOX_ROOT"
mkdir --parents \
      gnu/store \
      dev

# Create FIFO file to block the following sript at 'cat' untill it is written
mkfifo ./dev/sandbox-internal.pid

guix shell --container \
     coreutils guix shadow psmisc bash \
     --network \
     --user=user \
     --writable-root \
     --no-cwd \
     --link-profile \
     --share=./gnu/store=/gnu/store \
     --share=./dev/sandbox-internal.pid=/dev/sandbox-internal.pid \
     -- sh -c 'echo $$ > /dev/sandbox-internal.pid; exec sleep infinity' &

SANDBOX_PID=$!
echo '$SANDBOX_PID' > ./dev/sandbox.pid

# waits for the FIFO file the get written (avoid racing)
SANDBOX_INTERNAL_PID=$(cat ./dev/sandbox-internal.pid)

# now since the sandbox started the 'sleep' process we can get its PID
# the only child process (ignoring treads) is the guix process that sets namespace
SANDBOX_NS_SETTER_PID=$(pgrep --parent $SANDBOX_PID)
echo '$SANDBOX_NS_SETTER_PID' > ./dev/sandbox-ns-setter.pid

# the only process it starts is 'sleep' which is PID to id the namespace we can 'nsenter' to
SANDBOX_NS_PID=$(pgrep --parent $SANDBOX_NS_SETTER_PID)
echo '$SANDBOX_NS_PID' > ./dev/sandbox-ns.pid

# Report to user (stderr)
echo "Guix sandbox started:" 1>&2
echo "  - Shared dirs are bind mounted to: $SANDBOX_ROOT" 1>&2
echo "  - Sandbox PID:                     $SANDBOX_PID" 1>&2
echo "  - Sandbox PID that sets namespace: $SANDBOX_NS_SETTER_PID" 1>&2
echo "  - Sandbox's namespace PID:         $SANDBOX_NS_PID" 1>&2

# return pid to id the namespace
echo "$SANDBOX_NS_PID"
