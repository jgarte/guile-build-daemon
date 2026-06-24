# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

CHANNELS            := './env/guix/gxd/channels.scm'

GUIX_TM             := guix time-machine --channels=$(CHANNELS)

GUILE_DEV           := $(GUIX_TM) \
                       -- shell guile guile-ares-rs --pure --preserve=.*LANG.* \
                       -- guile -L './src' \
                                -L './tests' \
                                -L './dev'

GUIX_LOAD_PATH_ENV  := --load-path='./env/dev' \
                       --load-path='./env/guix'

GUILE_LOAD_PATH_DEV := "$$(cd ./env/dev && pwd):$$GUILE_LOAD_PATH"

CONFIG_DEV_ENV      := ./env/dev/gxd/config.sh

GUIX_DAEMON_DEV_PKG := '(@ (gxd packages) gxd)'
GUIX_DAEMON_DEV     := $(GUIX_TM) -- build $(GUIX_LOAD_PATH_ENV) \
                                     --no-grafts \
                                     --expression=$(GUIX_DAEMON_DEV_PKG)

TEST_REGULAR_ROOT   := /tmp/guix-gd-overlayfs-regular-$(USER)
TEST_REGULAR_SOCK   := /tmp/guix-gd-fallback-regular-$(USER).sock
TEST_RELAY_ROOT     := /tmp/guix-gd-overlayfs-relay-$(USER)
TEST_RELAY_SOCK     := /tmp/guix-gd-fallback-relay-$(USER).sock

ares:
	$(GUILE_DEV) -s './dev/gxd/ares-safe.scm'


test/differential:
	$(GUIX_TM) -- shell guile guile-ares-rs --pure --preserve=.*LANG.* --preserve='GUIX_GD_TEST_.*' \
	-- guile -L './src' \
	         -L './tests' \
	         -L './dev' \
	         -c "(use-modules (gxd differential-test)) (display (run-daemon-differential-tests)) (newline)"

daemon/build:
	$(GUIX_DAEMON_DEV)


daemon/init-build-users:
	$(CONFIG_DEV_ENV) \
	sh ./env/dev/gxd/init-dev-build-users.sh

container/start:
	$(CONFIG_DEV_ENV) \
	sh ./env/dev/gxd/contain-overlayfs.sh

daemon-fallback/start:
	$(GUIX_TM) -- shell -- \
	$(CONFIG_DEV_ENV) \
	sh ./env/dev/gxd/start-daemon.sh

daemon/start:
	$(CONFIG_DEV_ENV) \
	sh -c 'daemon_root="$$1"; \
	rm -f "$$GUIX_GD_DEV_ROOT/var/guix/daemon-socket/socket"; \
	"$$daemon_root"/bin/gxd \
	"$$GUIX_GD_DEV_ROOT/var/guix/daemon-socket/socket" \
	"$$GUIX_GD_DEV_SOCK" \
	| tee tmp/daemon.log' \
	sh "$$($(GUIX_DAEMON_DEV))"

container/regular/start:
	$(CONFIG_DEV_ENV) \
	GUIX_GD_DEV_ROOT=$(TEST_REGULAR_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_REGULAR_SOCK) \
	sh ./env/dev/gxd/contain-overlayfs.sh

container/relay/start:
	$(CONFIG_DEV_ENV) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_RELAY_SOCK) \
	sh ./env/dev/gxd/contain-overlayfs.sh

daemon-fallback/regular/start:
	$(GUIX_TM) -- shell -- \
	$(CONFIG_DEV_ENV) \
	GUIX_GD_DEV_ROOT=$(TEST_REGULAR_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_REGULAR_SOCK) \
	GUIX_GD_DAEMON_ARGS='--disable-chroot --disable-deduplication' \
	sh ./env/dev/gxd/start-daemon.sh

daemon-fallback/relay/start:
	$(GUIX_TM) -- shell -- \
	$(CONFIG_DEV_ENV) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_RELAY_SOCK) \
	GUIX_GD_DAEMON_ARGS='--disable-chroot --disable-deduplication' \
	sh ./env/dev/gxd/start-daemon.sh

daemon/relay/start:
	$(CONFIG_DEV_ENV) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_RELAY_SOCK) \
	sh -c 'daemon_root="$$1"; \
	rm -f "$(TEST_RELAY_ROOT)/var/guix/daemon-socket/socket"; \
	"$$daemon_root"/bin/gxd \
	"$(TEST_RELAY_ROOT)/var/guix/daemon-socket/socket" \
	"$(TEST_RELAY_SOCK)" \
	| tee tmp/daemon-relay.log' \
	sh "$$($(GUIX_DAEMON_DEV))"

container/shell:
	$(GUIX_TM) -- shell -- \
	$(CONFIG_DEV_ENV) \
	sh ./env/dev/gxd/start-shell.sh


container/regular/stop:
	$(CONFIG_DEV_ENV) \
	GUIX_GD_DEV_ROOT=$(TEST_REGULAR_ROOT) \
	sh ./env/dev/gxd/kill-overlayfs.sh

container/relay/stop:
	$(CONFIG_DEV_ENV) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	sh ./env/dev/gxd/kill-overlayfs.sh

container/stop:
	$(CONFIG_DEV_ENV) \
	sh ./env/dev/gxd/kill-overlayfs.sh

