# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser

# Block execution if the effective user ID is 0 (root)
ifeq ($(shell id -u), 0)
       $(error "These 'make' commands should not be called as root/sudo.")
endif

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

SUDO := $(shell command -v sudo)

# Testbox Disk Paths (writable by unprivileged user)
TESTBOX_DIRECTORY                := $(abspath target/testbox)
TESTBOX_DISK_MOUNT_POINT         = ${TESTBOX_DIRECTORY}/mnt
TESTBOX_DISK_BASE_SUBVOLUME_PATH = ${TESTBOX_DISK_MOUNT_POINT}/base
TESTBOX_DISK_IMAGE               = ${TESTBOX_DIRECTORY}/disk.img
TESTBOX_DISK_IMAGE_SIZE          = 10G
TESTBOX_DISK_BOOTSTRAP_ARCHIVE   = ${TESTBOX_DIRECTORY}/bootstrap.tar.gz

TESTBOX_DISK_ENV = env \
       SUDO=${SUDO} \
       TESTBOX_DISK_MOUNT_POINT=${TESTBOX_DISK_MOUNT_POINT} \
       TESTBOX_DISK_BASE_SUBVOLUME_PATH=${TESTBOX_DISK_BASE_SUBVOLUME_PATH} \
       TESTBOX_DISK_IMAGE=${TESTBOX_DISK_IMAGE} \
       TESTBOX_DISK_IMAGE_SIZE=${TESTBOX_DISK_IMAGE_SIZE} \
       TESTBOX_DISK_BOOTSTRAP_ARCHIVE=${TESTBOX_DISK_BOOTSTRAP_ARCHIVE}

TEST_ENV = $(DEV_ENV) env \
       LC_ALL=C.UTF-8 \
       TEST_RESOURCES_DIRECTORY="$(abspath test/resources)" \
       TESTBOX_DISK_MOUNT_POINT=${TESTBOX_DISK_MOUNT_POINT} \
       TESTBOX_DISK_BASE_SUBVOLUME_PATH=${TESTBOX_DISK_BASE_SUBVOLUME_PATH}

GUILE_DEV = $(TEST_ENV) guile ${GLP_DEV}

# ----------------------------------------------------------------------------

.PHONY: ares
ares:
	${GUILE_DEV} -c "((@ (ares server) run-nrepl-server))"

.PHONY: check
check:
	${TEST_ENV} ares-suitbl -- ${GLP_TEST}

.PHONY: testbox-disk/bootstrap-archive
testbox-disk/bootstrap-archive: ${TESTBOX_DISK_BOOTSTRAP_ARCHIVE}

${TESTBOX_DISK_BOOTSTRAP_ARCHIVE}: ${GUIX_CHANNELS_FILE} ./env/deps/gxd/env/guix/packages.scm
	mkdir -p "$(dir $@)"
	rm -f "$@"
	${GUIX} pack ${GLP_DEV_ENV} \
	      -e '(@ (gxd env guix packages) guix-package)' \
	      --localstatedir --root="$@"

.PHONY: testbox-disk/init
testbox-disk/init: testbox-disk/bootstrap-archive
	${DEV_ENV} ${TESTBOX_DISK_ENV} sh ./env/testbox-disk/init.sh

.PHONY: testbox-disk/mount
testbox-disk/mount: testbox-disk/init

.PHONY: testbox-disk/delete
testbox-disk/delete:
	${DEV_ENV} ${TESTBOX_DISK_ENV} sh ./env/testbox-disk/delete.sh
