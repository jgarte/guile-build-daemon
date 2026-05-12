#!/bin/sh
# Initialize dedicated build users. Requires real root privileges.

set -eu

GUIX_GD_GROUP="${GUIX_GD_GROUP:-guix-gd-build}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Skipping build-user initialization: not running as root."
  echo "If needed, run this script once as root to create ${GUIX_GD_GROUP}-01..10."
  exit 0
fi

echo "------------------------------------------"
echo "Configuration for dev guixdaemon build users:"
echo "  GUIX_GD_GROUP: $GUIX_GD_GROUP"
echo "------------------------------------------"

printf 'Init group/user(s)? [y/N]: '
read -r CONFIRM

case "$CONFIRM" in
  [yY][eE][sS]|[yY])
    echo "Proceeding with build user initialization..."
    if ! grep -q "^${GUIX_GD_GROUP}:" /etc/group; then
      groupadd --system "$GUIX_GD_GROUP"
    fi

    NOLOGIN_BIN="$(command -v nologin || true)"
    if [ -z "$NOLOGIN_BIN" ]; then
      NOLOGIN_BIN=/sbin/nologin
    fi

    for i in $(seq -w 1 10); do
      user_name="${GUIX_GD_GROUP}-${i}"
      if id "$user_name" >/dev/null 2>&1; then
        continue
      fi

      useradd -g "$GUIX_GD_GROUP" -G "$GUIX_GD_GROUP" \
        -d /var/empty -s "$NOLOGIN_BIN" \
        -c "Guix guile build daemon user $i" --system \
        "$user_name"
    done
    ;;
  *)
    echo "Aborting."
    exit 1
    ;;
esac
