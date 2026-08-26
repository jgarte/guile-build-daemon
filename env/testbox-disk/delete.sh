#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser

set -euo pipefail

: "${TESTBOX_DISK_MOUNT_POINT:?run with 'make testbox-disk/purge'}"
: "${TESTBOX_DISK_IMAGE:?run with 'make testbox-disk/purge'}"
: "${SUDO:?run with 'make testbox-disk/purge'}"

if findmnt -M "$TESTBOX_DISK_MOUNT_POINT" >/dev/null
then
    $SUDO umount "$TESTBOX_DISK_MOUNT_POINT"
    echo "'testbox disk' btrfs image is unmounted"
fi

rm -f "$TESTBOX_DISK_IMAGE"
rmdir "$TESTBOX_DISK_MOUNT_POINT" 2>/dev/null || true
echo "'testbox disk' image and its mount point are deleted"
