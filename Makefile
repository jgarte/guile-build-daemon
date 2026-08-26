# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser

GUIX_CHANNELS_FILE = ./env/guix/gxd/env/guix/channels.scm

# Guix requires `--unsafe-channel-evaluation' flag (UCE_FLAG) if the file that
# provides channels is not a simple list and needs to be evaluated; the older
# version of Guix does not accept this flag and will fail if it is set
GUIX_UCE_FLAG := $(shell \
                   guix time-machine --help 2>&1 | \
                   grep -q -- --unsafe-channel-evaluation && \
                   echo "--unsafe-channel-evaluation" \
                   )

GUIX_TM := guix time-machine $(GUIX_UCE_FLAG) --channels=${GUIX_CHANNELS_FILE}
GUIX = $(GUIX_TM) --

# Guile Load Paths (GLP)
GLP_DEV_ENV = -L ./env/guix \
              -L ./env/deps
GLP_GXD     = -L ./src/guile
GLP_TEST    = -L ./test/guile ${GLP_GXD}
GLP_DEV     = -L ./dev/guile ${GLP_TEST}

DEV_ENV = $(GUIX) shell ${GLP_DEV_ENV} \
          -e '(@ (gxd env guix packages) dev-env)' \
          --pure --preserve=.*LANG.* --
GUILE_DEV = $(DEV_ENV) guile ${GLP_DEV}

SUDO := $(shell command -v sudo)

# Testbox Disk Paths (writable by unprivileged user)
TESTBOX_DISK_MOUNT_POINT = ./tmp/.testbox-disk
TESTBOX_DISK_IMAGE       = ./tmp/.testbox-disk.image
TESTBOX_DISK_IMAGE_SIZE  = 10G

TESTBOX_DISK_ENV = env \
       SUDO=${SUDO} \
       TESTBOX_DISK_MOUNT_POINT=${TESTBOX_DISK_MOUNT_POINT} \
       TESTBOX_DISK_IMAGE=${TESTBOX_DISK_IMAGE} \
       TESTBOX_DISK_IMAGE_SIZE=${TESTBOX_DISK_IMAGE_SIZE}

# ----------------------------------------------------------------------------

.PHONY: ares
ares:
	${GUILE_DEV} -c "((@ (ares server) run-nrepl-server))"

.PHONY: check
check:
	${DEV_ENV} ares-suitbl -- ${GLP_TEST}

.PHONY: testbox-disk/init
testbox-disk/init:
	${DEV_ENV} ${TESTBOX_DISK_ENV} sh ./env/testbox-disk/init.sh

.PHONY: testbox-disk/delete
testbox-disk/delete:
	${DEV_ENV} ${TESTBOX_DISK_ENV} sh ./env/testbox-disk/delete.sh
