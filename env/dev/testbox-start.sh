#!/bin/sh
# Start a small Guix testbox.
#
# It creates a fake root and two long-lived processes, each in its own user and
# mount namespace:
#   - user:        regular Guix client user
#   - guix-daemon: regular daemon user
#
# The two namespaces see the same fake root, so they share /var/guix and the
# daemon socket.

set -eu

PROJECT_ROOT=$(pwd)
CHANNELS=${CHANNELS:-env/guix/channels.scm}
TESTBOX_ROOT=${1:-$(mktemp -d /tmp/guix-testbox-XXXXXX)}

TESTBOX_USER_UID=${TESTBOX_USER_UID:-1000}
TESTBOX_USER_GID=${TESTBOX_USER_GID:-1000}
TESTBOX_DAEMON_UID=${TESTBOX_DAEMON_UID:-994}
TESTBOX_DAEMON_GID=${TESTBOX_DAEMON_GID:-994}

# /home/user/.config/guix/current must be a symlink to a store profile.  If
# "current" is made as a directory, guix gc rejects it as a non-store path.
mkdir -p "$TESTBOX_ROOT/home/user/.config/guix"
GUIX_PINNED_STORE=$(readlink -f "$(guix time-machine --channels="$CHANNELS")")
rm -rf "$TESTBOX_ROOT/home/user/.config/guix/current"
ln -s "$GUIX_PINNED_STORE" \
   "$TESTBOX_ROOT/home/user/.config/guix/current"

GUIX_PINNED="$TESTBOX_ROOT/home/user/.config/guix/current"
GUIX_PROFILE="$TESTBOX_ROOT/home/user/.guix-profile"
GUIX_PROFILE_IN_TESTBOX="/home/user/.guix-profile"

# Build the baseline user profile.  Keep tools here explicit: this profile is
# the only userland visible from the testbox.
guix time-machine --channels="$CHANNELS" -- \
     package --profile="$GUIX_PROFILE" --install \
     coreutils shadow psmisc bash util-linux curl iputils libcap \
     grep findutils procps nss-certs \
     >/dev/null 2>&1

mkdir -p \
      "$TESTBOX_ROOT/bin" \
      "$TESTBOX_ROOT/dev" \
      "$TESTBOX_ROOT/etc/guix" \
      "$TESTBOX_ROOT/etc/ssl" \
      "$TESTBOX_ROOT/gnu/store" \
      "$TESTBOX_ROOT/home/user" \
      "$TESTBOX_ROOT/proc" \
      "$TESTBOX_ROOT/run" \
      "$TESTBOX_ROOT/tmp" \
      "$TESTBOX_ROOT/var/empty" \
      "$TESTBOX_ROOT/var/guix/daemon-socket" \
      "$TESTBOX_ROOT/var/guix/db" \
      "$TESTBOX_ROOT/var/guix/gcroots" \
      "$TESTBOX_ROOT/var/guix/profiles/per-user/user" \
      "$TESTBOX_ROOT/var/guix/profiles/per-user/guix-daemon" \
      "$TESTBOX_ROOT/var/guix/temproots" \
      "$TESTBOX_ROOT/var/log/guix"
chmod 1777 "$TESTBOX_ROOT/tmp" "$TESTBOX_ROOT/var/guix/temproots"

# Minimal NSS data.  /etc/services is required for Guile/GnuTLS getaddrinfo
# calls that use service names such as "https".
cat > "$TESTBOX_ROOT/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
user:x:$TESTBOX_USER_UID:$TESTBOX_USER_GID:Testbox user:/home/user:/bin/bash
guix-daemon:x:$TESTBOX_DAEMON_UID:$TESTBOX_DAEMON_GID:Guix daemon:/var/empty:/bin/sh
nobody:x:65534:65534:nobody:/var/empty:/bin/sh
EOF

cat > "$TESTBOX_ROOT/etc/group" <<EOF
root:x:0:
user:x:$TESTBOX_USER_GID:
guix-daemon:x:$TESTBOX_DAEMON_GID:
guixbuild:x:30000:
nogroup:x:65534:
EOF

cat > "$TESTBOX_ROOT/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost
EOF

cat > "$TESTBOX_ROOT/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
hosts: files dns
services: files
protocols: files
EOF

cat > "$TESTBOX_ROOT/etc/protocols" <<'EOF'
ip 0 IP
tcp 6 TCP
udp 17 UDP
EOF

if [ -r /etc/resolv.conf ]; then
    cp /etc/resolv.conf "$TESTBOX_ROOT/etc/resolv.conf"
else
    printf 'nameserver 1.1.1.1\n' > "$TESTBOX_ROOT/etc/resolv.conf"
fi

if [ -r /etc/services ]; then
    cp /etc/services "$TESTBOX_ROOT/etc/services"
else
    cat > "$TESTBOX_ROOT/etc/services" <<'EOF'
http 80/tcp
https 443/tcp
domain 53/tcp
domain 53/udp
EOF
fi

cp "$PROJECT_ROOT/env/guix/acl" "$TESTBOX_ROOT/etc/guix/acl"
rm -rf "$TESTBOX_ROOT/etc/ssl/certs"
ln -s "$GUIX_PROFILE_IN_TESTBOX/etc/ssl/certs" "$TESTBOX_ROOT/etc/ssl/certs"

# Shell entrypoints.
ln -sf "$GUIX_PROFILE_IN_TESTBOX/bin/sh" "$TESTBOX_ROOT/bin/sh"
ln -sf "$GUIX_PROFILE_IN_TESTBOX/bin/bash" "$TESTBOX_ROOT/bin/bash"

# Collect the bootstrap closure visible in the fake store.
GUIX_PROFILE_STORE=$(readlink -f "$GUIX_PROFILE")
GUIX_PINNED_STORE=$(readlink -f "$GUIX_PINNED")
guix gc --requisites \
    "$GUIX_PROFILE_STORE" \
    "$GUIX_PINNED_STORE" \
    | sort -u > "$TESTBOX_ROOT/store-requisites.list"

# Guix-daemon's DB must know about the store items mounted below.  Otherwise it
# tries to substitute an already mounted read-only path and fails with EROFS.
: > "$TESTBOX_ROOT/store-reference-graph"
while IFS= read -r store_item; do
    refs=$(guix gc --references "$store_item" | sed '/^$/d')
    ref_count=$(printf '%s\n' "$refs" | sed '/^$/d' | wc -l | tr -d ' ')
    deriver=$(guix gc --derivers "$store_item" | sed -n '1p')

    printf '%s\n' "$store_item" >> "$TESTBOX_ROOT/store-reference-graph"
    printf '%s\n' "$deriver" >> "$TESTBOX_ROOT/store-reference-graph"
    printf '%s\n' "$ref_count" >> "$TESTBOX_ROOT/store-reference-graph"
    printf '%s\n' "$refs" | sed '/^$/d' >> "$TESTBOX_ROOT/store-reference-graph"
done < "$TESTBOX_ROOT/store-requisites.list"

cat > "$TESTBOX_ROOT/register-store.scm" <<'EOF'
(use-modules (guix store database)
             (guix build store-copy))

(call-with-database "/var/guix/db/db.sqlite"
  (lambda (db)
    (register-items db
                    (call-with-input-file "/store-reference-graph"
                      read-reference-graph))))
EOF

cat > "$TESTBOX_ROOT/testbox-enter.sh" <<'EOF'
#!/bin/sh
set -eu

: "${TESTBOX_ROOT:?}"

mount --make-rprivate /
mount --bind "$TESTBOX_ROOT" "$TESTBOX_ROOT"

# Mount only the profile closure into the fake /gnu/store, read-only.
while IFS= read -r store_item; do
    item_name=${store_item##*/}
    target="$TESTBOX_ROOT/gnu/store/$item_name"

    if [ -d "$store_item" ]; then
        mkdir -p "$target"
    else
        mkdir -p "${target%/*}"
        [ -e "$target" ] || : > "$target"
    fi

    mount --bind "$store_item" "$target"
    mount -o remount,bind,ro "$target"
done < "$TESTBOX_ROOT/store-requisites.list"

mount --rbind /dev "$TESTBOX_ROOT/dev"
mount --rbind /proc "$TESTBOX_ROOT/proc"
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$TESTBOX_ROOT/tmp"

cd "$TESTBOX_ROOT"
mkdir -p .old-root
pivot_root . .old-root

export PATH=/bin

export GUIX_PROFILE=/home/user/.config/guix/current
. "$GUIX_PROFILE/etc/profile"

export GUIX_PROFILE=/home/user/.guix-profile
. "$GUIX_PROFILE/etc/profile"

export SSL_CERT_DIR=/etc/ssl/certs
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

exec "$@"
EOF
chmod +x "$TESTBOX_ROOT/testbox-enter.sh"

run_in_testbox_namespace() {
    inner_uid=$1
    inner_gid=$2
    shift 2

    TESTBOX_ROOT=$TESTBOX_ROOT \
    unshare --user \
            --map-user="$inner_uid" \
            --map-group="$inner_gid" \
            --keep-caps \
            --mount \
            /bin/sh "$TESTBOX_ROOT/testbox-enter.sh" "$@"
}

# Initialize the isolated store database before any daemon opens it.
rm -f "$TESTBOX_ROOT/var/guix/db/db.sqlite"*
run_in_testbox_namespace \
    "$TESTBOX_USER_UID" \
    "$TESTBOX_USER_GID" \
    /bin/sh -eu -c \
    'GUIX_STATE_DIRECTORY=/var/guix GUIX_CONFIGURATION_DIRECTORY=/etc/guix guix repl -- /register-store.scm >/dev/null 2>&1'

start_sleep_namespace() {
    role=$1
    inner_uid=$2
    inner_gid=$3
    login=$4
    home=$5
    fifo="$TESTBOX_ROOT/testbox-$role.pid.fifo"

    rm -f "$fifo"
    mkfifo "$fifo"

    TESTBOX_ROOT=$TESTBOX_ROOT \
    TESTBOX_ROLE=$role \
    TESTBOX_LOGIN=$login \
    TESTBOX_HOME=$home \
    unshare --user \
            --map-user="$inner_uid" \
            --map-group="$inner_gid" \
            --keep-caps \
            --mount \
            /bin/sh "$TESTBOX_ROOT/testbox-enter.sh" \
            /bin/sh -eu -c '
                TESTBOX_TERM=${TERM:-xterm-256color}
                echo "$$" > "/testbox-$TESTBOX_ROLE.pid.fifo"
                exec env -i \
                    HOME="$TESTBOX_HOME" \
                    USER="$TESTBOX_LOGIN" \
                    LOGNAME="$TESTBOX_LOGIN" \
                    SHELL=/bin/bash \
                    TERM="$TESTBOX_TERM" \
                    PATH="$PATH" \
                    GUIX_PROFILE="$GUIX_PROFILE" \
                    SSL_CERT_DIR="$SSL_CERT_DIR" \
                    SSL_CERT_FILE="$SSL_CERT_FILE" \
                    sleep infinity
            ' &

    outer_pid=$!
    ns_pid=$(cat "$fifo")
    rm -f "$fifo"

    printf '%s\n' "$outer_pid" > "$TESTBOX_ROOT/testbox-$role.pid"
    printf '%s\n' "$ns_pid" > "$TESTBOX_ROOT/testbox-$role-ns.pid"
}

start_sleep_namespace \
    guix-daemon \
    "$TESTBOX_DAEMON_UID" \
    "$TESTBOX_DAEMON_GID" \
    guix-daemon \
    /var/empty

start_sleep_namespace \
    user \
    "$TESTBOX_USER_UID" \
    "$TESTBOX_USER_GID" \
    user \
    /home/user

GUIX_DAEMON_NS_PID=$(cat "$TESTBOX_ROOT/testbox-guix-daemon-ns.pid")
USER_NS_PID=$(cat "$TESTBOX_ROOT/testbox-user-ns.pid")

# Report to user (stderr).
echo "Testbox started:" 1>&2
echo "  - Fake root:                       $TESTBOX_ROOT" 1>&2
echo "  - guix-daemon namespace PID:       $GUIX_DAEMON_NS_PID" 1>&2
echo "  - user namespace PID:              $USER_NS_PID" 1>&2
echo "" 1>&2
echo "Start daemon:" 1>&2
echo "  env/dev/testbox-shell.sh $GUIX_DAEMON_NS_PID guix-daemon --disable-chroot --build-users-group= --no-build-hook --substitute-urls=https://ci.guix.gnu.org" 1>&2
echo "" 1>&2
echo "Run client command:" 1>&2
echo "  env/dev/testbox-shell.sh $USER_NS_PID guix build hello" 1>&2

# Machine-readable stdout.
printf 'guix-daemon %s\n' "$GUIX_DAEMON_NS_PID"
printf 'user %s\n' "$USER_NS_PID"
