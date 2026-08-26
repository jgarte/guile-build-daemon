#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser

set -euo pipefail

: "${TESTBOX_DISK_MOUNT_POINT:?run with 'make testbox-disk/init'}"
: "${TESTBOX_DISK_IMAGE:?run with 'make testbox-disk/init'}"
: "${TESTBOX_DISK_IMAGE_SIZE:?run with 'make testbox-disk/init'}"
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
    USER_ID=$(id -u); GROUP_ID=$(id -g)
    $SUDO chown "$USER_ID:$GROUP_ID" "$TESTBOX_DISK_MOUNT_POINT"
    echo "'testbox disk' btrfs image is mounted at $TESTBOX_DISK_MOUNT_POINT"
    # prepare testbox init file system
    TESTBOX_INIT_FS_PATH="$TESTBOX_DISK_MOUNT_POINT/init-fs"
    if ! test -f "$TESTBOX_INIT_FS_PATH"
    then
        echo "populating 'testbox disk' with init fs..."
        TESTBOX_INIT_FS_TAR=$(guix pack \
                                   -L ./env/guix \
                                   -L ./env/deps \
                                   -e '(@ (gxd env guix packages) guix-package)' \
                                   --localstatedir)
        btrfs subvolume create "$TESTBOX_INIT_FS_PATH" >/dev/null
        tar --extract --file "$TESTBOX_INIT_FS_TAR" --directory "$TESTBOX_INIT_FS_PATH" \
            --no-same-owner --same-permissions
        btrfs property set -t s "$TESTBOX_INIT_FS_PATH" ro true
        echo "'testbox disk' is populated with init fs in $TESTBOX_INIT_FS_PATH"
    fi
fi


