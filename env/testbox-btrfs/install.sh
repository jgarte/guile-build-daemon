#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser

set -euo pipefail

: "${TESTBOX_BTRFS:?run through make}"
: "${TESTBOX_BTRFS_IMAGE:?run through make}"
: "${TESTBOX_BTRFS_IMAGE_SIZE:?run through make}"

if [[ ${EUID} -eq 0 ]]; then
  echo "error: run make testbox-btrfs/install as yourself, not under sudo." >&2
  exit 1
fi

cd "$(dirname "$0")/../.."

GUIXTM=(./env/guix/time-machine)
DEV_ENV=("${GUIXTM[@]}" --
         shell -L ./env/guix -L ./env/deps
         -e '(@ (gxd env guix packages) dev-env)'
         --pure --preserve=.*LANG.* --preserve=^TESTBOX_BTRFS --)

if ! awk -v m="$TESTBOX_BTRFS" '$2 == m { f = 1 } END { exit !f }' /proc/mounts; then
  mkfs=$("${DEV_ENV[@]}" guile -c \
    '(display (search-path (string-split (getenv "PATH") #\:) "mkfs.btrfs"))')

  if ! sudo test -f "$TESTBOX_BTRFS_IMAGE"; then
    sudo mkdir -p "$(dirname "$TESTBOX_BTRFS_IMAGE")"
    image="$TESTBOX_BTRFS_IMAGE.new.$$"
    trap 'sudo rm -f "$image"' EXIT
    sudo fallocate -l "$TESTBOX_BTRFS_IMAGE_SIZE" "$image"
    sudo "$mkfs" -q -L gxd-testboxes "$image"
    sudo mv "$image" "$TESTBOX_BTRFS_IMAGE"
    trap - EXIT
  fi

  sudo mkdir -p "$TESTBOX_BTRFS"
  sudo mount -o loop,rw,nosuid,nodev,noatime,user_subvol_rm_allowed \
    "$TESTBOX_BTRFS_IMAGE" "$TESTBOX_BTRFS"
  trap 'sudo umount "$TESTBOX_BTRFS"' EXIT
  sudo chown "$(id -u):$(id -g)" "$TESTBOX_BTRFS"
  trap - EXIT
fi

mkdir -p "$TESTBOX_BTRFS/testbox-roots"

base="$TESTBOX_BTRFS/base"
if [[ -e $base ]]; then
  printf '%s\n' "$base"
  exit 0
fi

btrfs=$("${DEV_ENV[@]}" guile -c \
  '(display (search-path (string-split (getenv "PATH") #\:) "btrfs"))')
pack=$("${GUIXTM[@]}" -- \
       pack -L ./env/guix -L ./env/deps \
       --localstatedir \
       --manifest=./test/guile/gxd/testbox/base-manifest.scm)

"$btrfs" subvolume create "$base" >/dev/null
trap '"$btrfs" subvolume delete "$base" >/dev/null' EXIT
tar --extract --file "$pack" --directory "$base" \
  --no-same-owner --same-permissions
"$btrfs" property set -t s "$base" ro true
trap - EXIT

printf '%s\n' "$base"
