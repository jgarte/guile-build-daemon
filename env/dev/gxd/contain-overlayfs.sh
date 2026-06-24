#!/bin/sh
# Configure a rootless sandbox with a seeded /gnu/store for a dev guix-daemon.

set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "${SCRIPT_DIR}/config.defaults.sh"

# Re-derive root-relative paths for the selected GXD_DEV_ROOT.
GXD_STORE_UPPER_DIR="${GXD_DEV_ROOT}/gnu/store-upper"
GXD_STORE_WORK_DIR="${GXD_DEV_ROOT}/gnu/store-work"
GXD_STORE_LOWER_DIR="${GXD_DEV_ROOT}/gnu/store-lower"
GXD_STORE_ITEMS_FILE="${GXD_DEV_ROOT}/gnu/store-items.txt"
GXD_VAR_GUIX_DIR="${GXD_DEV_ROOT}/var/guix"
GXD_ETC_GUIX_DIR="${GXD_DEV_ROOT}/etc/guix"
GXD_OVERLAYFS_PID_FILE="${GXD_DEV_ROOT}/overlayfs-container.pid"

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
  tmp_file="${GXD_STORE_ITEMS_FILE}.tmp"
  : > "$tmp_file"

  for candidate in $GXD_RUNTIME_COMMANDS; do
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
    printf 'ERROR: no runtime store items were collected. Check GXD_RUNTIME_COMMANDS.\n' >&2
    exit 1
  fi

  LC_ALL=C sort -u "$tmp_file" > "$GXD_STORE_ITEMS_FILE"
  rm -f "$tmp_file"
}

seed_store_links() {
  while IFS= read -r path; do
    case "$path" in
      /gnu/store/*)
        item="${path#/gnu/store/}"
        item="${item%%/*}"
        [ -n "$item" ] || continue

        target="${GXD_STORE_LOWER_DIR}/${item}"
        link="${GXD_STORE_UPPER_DIR}/${item}"

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
  done < "$GXD_STORE_ITEMS_FILE"
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
  "${GXD_STORE_WORK_DIR}" \
  "${GXD_STORE_UPPER_DIR}" \
  "${GXD_STORE_LOWER_DIR}" \
  "$(dirname -- "${GXD_STORE_ITEMS_FILE}")" \
  "${GXD_VAR_GUIX_DIR}/daemon-socket" \
  "${GXD_VAR_GUIX_DIR}/db" \
  "${GXD_VAR_GUIX_DIR}/discover" \
  "${GXD_VAR_GUIX_DIR}/gcroots" \
  "${GXD_VAR_GUIX_DIR}/offload" \
  "${GXD_VAR_GUIX_DIR}/substitute" \
  "${GXD_VAR_GUIX_DIR}/temproots" \
  "${GXD_VAR_GUIX_DIR}/profiles/per-user" \
  "${GXD_DEV_ROOT}/var/log/guix" \
  "${GXD_ETC_GUIX_DIR}"

touch "${GXD_VAR_GUIX_DIR}/gc.lock"

if [ -f /etc/guix/acl ]; then
  cp -f /etc/guix/acl "${GXD_ETC_GUIX_DIR}/acl"
  chmod u+rw "${GXD_ETC_GUIX_DIR}/acl"
elif [ ! -f "${GXD_ETC_GUIX_DIR}/acl" ]; then
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
 )" > "${GXD_ETC_GUIX_DIR}/acl"
fi

chmod 0700 "${GXD_STORE_WORK_DIR}"

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

ITEM_COUNT="$(wc -l < "${GXD_STORE_ITEMS_FILE}" | tr -d '[:space:]')"

echo "== gxd /gnu/store seeded runtime (rootless) =="
echo "daemon user:   ${GXD_DAEMON_USER}"
echo "daemon group:  ${GXD_DAEMON_GROUP}"
echo "daemon bin:    ${GXD_DAEMON_BIN}"
echo "build group:   ${GXD_GROUP}"
echo "/gnu/store -> bind:"
echo "                lower=${GXD_STORE_LOWER_DIR} (host /gnu/store bind mount)"
echo "                upper=${GXD_STORE_UPPER_DIR} (writable seeded links)"
echo "                items=${ITEM_COUNT} (${GXD_STORE_ITEMS_FILE})"
echo "runtime cmds:  ${GXD_RUNTIME_COMMANDS}"
echo "/var/guix{...} -> ${GXD_VAR_GUIX_DIR}"
echo "/etc/guix -> ${GXD_ETC_GUIX_DIR}"
echo "namespace mode: unshare --user --map-root-user + unshare --mount"
echo

printf 'Start rootless dev container? [y/N]: '
read -r CONFIRM

case "$CONFIRM" in
  [yY][eE][sS]|[yY])
    exec unshare --user --map-root-user --fork -- env \
      GXD_DEV_ROOT="${GXD_DEV_ROOT}" \
      GXD_STORE_UPPER_DIR="${GXD_STORE_UPPER_DIR}" \
      GXD_STORE_WORK_DIR="${GXD_STORE_WORK_DIR}" \
      GXD_STORE_LOWER_DIR="${GXD_STORE_LOWER_DIR}" \
      GXD_STORE_ITEMS_FILE="${GXD_STORE_ITEMS_FILE}" \
      GXD_RUNTIME_COMMANDS="${GXD_RUNTIME_COMMANDS}" \
      GXD_VAR_GUIX_DIR="${GXD_VAR_GUIX_DIR}" \
      GXD_ETC_GUIX_DIR="${GXD_ETC_GUIX_DIR}" \
      GXD_DAEMON_USER="${GXD_DAEMON_USER}" \
      GXD_DAEMON_GROUP="${GXD_DAEMON_GROUP}" \
      GXD_DAEMON_BIN="${GXD_DAEMON_BIN}" \
      GXD_GROUP="${GXD_GROUP}" \
      /bin/sh -c 'exec unshare --mount --fork -- /bin/sh "$1"' \
      sh "${SCRIPT_DIR}/init-overlayfs.sh"
    ;;
  *)
    echo "Aborting."
    exit 1
    ;;
esac
