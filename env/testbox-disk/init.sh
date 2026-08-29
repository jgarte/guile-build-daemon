#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser

set -euo pipefail

: "${TESTBOX_DISK_MOUNT_POINT:?run with 'make testbox-disk/init'}"
: "${TESTBOX_DISK_IMAGE:?run with 'make testbox-disk/init'}"
: "${TESTBOX_DISK_IMAGE_SIZE:?run with 'make testbox-disk/init'}"
: "${TESTBOX_BOOTSTRAP_ARCHIVE:?run with 'make testbox-disk/init'}"
: "${SUDO:?run with 'make testbox-disk/init'}"

if findmnt -M "$TESTBOX_DISK_MOUNT_POINT" >/dev/null
then
    echo "'testbox disk' btrfs image is already mounted at $TESTBOX_DISK_MOUNT_POINT"
else
    # Ensure that btrfs image exists
    if ! test -f "$TESTBOX_DISK_IMAGE"
    then
        echo "creating 'testbox disk' btrfs image..."
        mkdir -p "$(dirname "$TESTBOX_DISK_IMAGE")"
        fallocate -l "$TESTBOX_DISK_IMAGE_SIZE" "$TESTBOX_DISK_IMAGE"
        $SUDO mkfs.btrfs -q -L testbox-disk "$TESTBOX_DISK_IMAGE"
        echo "'testbox disk' btrfs image is created at $TESTBOX_DISK_IMAGE"
    fi
    # mount btrfs image
    echo "mounting 'testbox disk' btrfs image..."
    mkdir -p "$TESTBOX_DISK_MOUNT_POINT"
    $SUDO mount -o loop,rw,nosuid,nodev,noatime,user_subvol_rm_allowed \
          "$TESTBOX_DISK_IMAGE" "$TESTBOX_DISK_MOUNT_POINT"
    uid=$(id -u); gid=$(id -g)
    $SUDO chown "$uid:$gid" "$TESTBOX_DISK_MOUNT_POINT"
    echo "'testbox disk' btrfs image is mounted at $TESTBOX_DISK_MOUNT_POINT"
    # prepare testbox base subvolume
    base_subvolume="$TESTBOX_DISK_MOUNT_POINT/base"
    if ! test -f "$base_subvolume"
    then
        echo "populating 'testbox disk' base..."
        btrfs subvolume create "$base_subvolume" >/dev/null
        tar --extract --file "$TESTBOX_BOOTSTRAP_ARCHIVE" \
            --directory "$base_subvolume" \
            --no-same-owner --same-permissions
        btrfs property set -t s "$base_subvolume" ro true
        echo "'testbox disk' base is populated at $base_subvolume"
    fi
fi


