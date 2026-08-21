#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser

set -euo pipefail

: "${TESTBOX_BTRFS:?run through make}"
: "${TESTBOX_BTRFS_IMAGE:?run through make}"

if [[ ${EUID} -eq 0 ]]; then
  echo "error: run make testbox-btrfs/remove as yourself, not under sudo." >&2
  exit 1
fi

if awk -v m="$TESTBOX_BTRFS" '$2 == m { f = 1 } END { exit !f }' /proc/mounts; then
  sudo umount "$TESTBOX_BTRFS"
fi

sudo rm -f "$TESTBOX_BTRFS_IMAGE"
sudo rmdir "$TESTBOX_BTRFS" 2>/dev/null || true
