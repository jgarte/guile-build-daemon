#!/bin/sh
# Configure a rootless sandbox with a seeded /gnu/store for a dev guix-daemon.

set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/config.defaults.sh"

# Re-derive root-relative paths for the selected GUIX_GD_DEV_ROOT.
GUIX_GD_STORE_UPPER_DIR="${GUIX_GD_DEV_ROOT}/gnu/store-upper"
GUIX_GD_STORE_WORK_DIR="${GUIX_GD_DEV_ROOT}/gnu/store-work"
GUIX_GD_STORE_LOWER_DIR="${GUIX_GD_DEV_ROOT}/gnu/store-lower"
GUIX_GD_STORE_ITEMS_FILE="${GUIX_GD_DEV_ROOT}/gnu/store-items.txt"
GUIX_GD_VAR_GUIX_DIR="${GUIX_GD_DEV_ROOT}/var/guix"
GUIX_GD_ETC_GUIX_DIR="${GUIX_GD_DEV_ROOT}/etc/guix"
GUIX_GD_OVERLAYFS_PID_FILE="${GUIX_GD_DEV_ROOT}/overlayfs-container.pid"

resolve_command_path() {
  candidate="$1"

  if [ -x "$candidate" ]; then
    readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
    return 0
  fi

  resolved="$(command -v "$candidate" 2>/dev/null || true)"
  if [ -z "$resolved" ]; then
    return 1
  fi

  readlink -f "$resolved" 2>/dev/null || printf '%s\n' "$resolved"
}

collect_runtime_store_items() {
  tmp_file="${GUIX_GD_STORE_ITEMS_FILE}.tmp"
  : > "$tmp_file"

  for candidate in $GUIX_GD_RUNTIME_COMMANDS; do
    resolved="$(resolve_command_path "$candidate" 2>/dev/null || true)"
    if [ -z "$resolved" ]; then
      printf 'WARNING: runtime command not found: %s\n' "$candidate" >&2
      continue
    fi

    case "$resolved" in
      /gnu/store/*)
        item="${resolved#/gnu/store/}"
        item="${item%%/*}"
        root="/gnu/store/${item}"
        printf '%s\n' "$root" >> "$tmp_file"
        guix gc --requisites "$root" >> "$tmp_file"
        ;;
      *)
        printf 'WARNING: runtime command outside /gnu/store: %s -> %s\n' "$candidate" "$resolved" >&2
        ;;
    esac
  done

  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file"
    printf 'ERROR: no runtime store items were collected. Check GUIX_GD_RUNTIME_COMMANDS.\n' >&2
    exit 1
  fi

  LC_ALL=C sort -u "$tmp_file" > "$GUIX_GD_STORE_ITEMS_FILE"
  rm -f "$tmp_file"
}

seed_store_links() {
  while IFS= read -r path; do
    case "$path" in
      /gnu/store/*)
        item="${path#/gnu/store/}"
        item="${item%%/*}"
        [ -n "$item" ] || continue

        target="${GUIX_GD_STORE_LOWER_DIR}/${item}"
        link="${GUIX_GD_STORE_UPPER_DIR}/${item}"

        if [ -L "$link" ]; then
          current_target="$(readlink "$link" 2>/dev/null || true)"
          if [ "$current_target" = "$target" ]; then
            continue
          fi
          rm -f "$link"
        elif [ -e "$link" ]; then
          # Keep entries created by previous daemon runs.
          continue
        fi

        ln -s "$target" "$link"
        ;;
    esac
  done < "$GUIX_GD_STORE_ITEMS_FILE"
}

if ! command -v unshare >/dev/null 2>&1; then
  printf 'ERROR: unshare not found in PATH.\n' >&2
  exit 1
fi

if ! command -v guix >/dev/null 2>&1; then
  printf 'ERROR: guix not found in PATH.\n' >&2
  exit 1
fi

mkdir -p \
  "${GUIX_GD_STORE_WORK_DIR}" \
  "${GUIX_GD_STORE_UPPER_DIR}" \
  "${GUIX_GD_STORE_LOWER_DIR}" \
  "$(dirname -- "${GUIX_GD_STORE_ITEMS_FILE}")" \
  "${GUIX_GD_VAR_GUIX_DIR}/daemon-socket" \
  "${GUIX_GD_VAR_GUIX_DIR}/db" \
  "${GUIX_GD_VAR_GUIX_DIR}/discover" \
  "${GUIX_GD_VAR_GUIX_DIR}/gcroots" \
  "${GUIX_GD_VAR_GUIX_DIR}/offload" \
  "${GUIX_GD_VAR_GUIX_DIR}/substitute" \
  "${GUIX_GD_VAR_GUIX_DIR}/temproots" \
  "${GUIX_GD_VAR_GUIX_DIR}/profiles/per-user" \
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
  /var/guix/profiles/per-user \
  /var/log/guix \
  /etc/guix

do
  if [ ! -e "$path" ]; then
    printf 'ERROR: required path does not exist: %s\n' "$path" >&2
    exit 1
  fi
done

collect_runtime_store_items
seed_store_links

ITEM_COUNT="$(wc -l < "${GUIX_GD_STORE_ITEMS_FILE}" | tr -d '[:space:]')"

echo "== guix-gd /gnu/store seeded runtime (rootless) =="
echo "daemon user:   ${GUIX_GD_DAEMON_USER}"
echo "daemon group:  ${GUIX_GD_DAEMON_GROUP}"
echo "daemon bin:    ${GUIX_GD_DAEMON_BIN}"
echo "build group:   ${GUIX_GD_GROUP}"
echo "/gnu/store -> bind:"
echo "                lower=${GUIX_GD_STORE_LOWER_DIR} (host /gnu/store bind mount)"
echo "                upper=${GUIX_GD_STORE_UPPER_DIR} (writable seeded links)"
echo "                items=${ITEM_COUNT} (${GUIX_GD_STORE_ITEMS_FILE})"
echo "runtime cmds:  ${GUIX_GD_RUNTIME_COMMANDS}"
echo "/var/guix{...} -> ${GUIX_GD_VAR_GUIX_DIR}"
echo "/etc/guix -> ${GUIX_GD_ETC_GUIX_DIR}"
echo "namespace mode: unshare --user --map-root-user + unshare --mount"
echo

printf 'Start rootless dev container? [y/N]: '
read -r CONFIRM

case "$CONFIRM" in
  [yY][eE][sS]|[yY])
    exec unshare --user --map-root-user --fork -- env \
      GUIX_GD_DEV_ROOT="${GUIX_GD_DEV_ROOT}" \
      GUIX_GD_STORE_UPPER_DIR="${GUIX_GD_STORE_UPPER_DIR}" \
      GUIX_GD_STORE_WORK_DIR="${GUIX_GD_STORE_WORK_DIR}" \
      GUIX_GD_STORE_LOWER_DIR="${GUIX_GD_STORE_LOWER_DIR}" \
      GUIX_GD_STORE_ITEMS_FILE="${GUIX_GD_STORE_ITEMS_FILE}" \
      GUIX_GD_RUNTIME_COMMANDS="${GUIX_GD_RUNTIME_COMMANDS}" \
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
