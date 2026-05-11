# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

CHANNELS            := './env/guix/guix-gd/channels.scm'

GUIX_TM             := guix time-machine --channels=$(CHANNELS)

GUILE_DEV           := $(GUIX_TM) \
                       -- shell guile guile-ares-rs --pure --preserve=.*LANG.* \
                       -- guile -L './src/guix-daemon' \
                                -L './tests/guix-daemon' \
                                -L './dev/guix-daemon'

GUIX_LOAD_PATH_ENV  := --load-path='./env/dev' \
                       --load-path='./env/guix'

GUILE_LOAD_PATH_DEV := "$$(cd ./env/dev && pwd):$$GUILE_LOAD_PATH"

CONFIG_DEV_ENV      := GUILE_LOAD_PATH=$(GUILE_LOAD_PATH_DEV) \
                        guile -c "(display ((@ (guix-gd config) config-dev-env)))"

GUIX_DAEMON_DEV_PKG := '(@ (guix-gd packages) guix-gd-daemon)'
GUIX_DAEMON_DEV     := $(GUIX_TM) -- build $(GUIX_LOAD_PATH_ENV) \
                                     --no-grafts \
                                     --expression=$(GUIX_DAEMON_DEV_PKG)

TEST_REGULAR_ROOT   := /guix-gd-overlayfs-regular
TEST_REGULAR_SOCK   := /tmp/guix-gd-fallback-regular.sock
TEST_RELAY_ROOT     := /guix-gd-overlayfs-relay
TEST_RELAY_SOCK     := /tmp/guix-gd-fallback-relay.sock

ares:
	$(GUILE_DEV) -s './dev/guix-daemon/ares-safe.scm'


test/differential:
	$(GUIX_TM) -- shell guile guile-ares-rs --pure --preserve=.*LANG.* --preserve='GUIX_GD_TEST_.*' \
	-- guile -L './src/guix-daemon' \
	         -L './tests/guix-daemon' \
	         -L './dev/guix-daemon' \
	         -c "(use-modules (guix-gd daemon differential-test)) (display (run-daemon-differential-tests)) (newline)"

daemon/build:
	$(GUIX_DAEMON_DEV)


daemon/init-build-users:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/init-dev-build-users.sh

container/start:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/contain-overlayfs.sh

daemon-fallback/start:
	$(GUIX_TM) -- shell -- \
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/start-daemon.sh

daemon/start:
	sudo env $$($(CONFIG_DEV_ENV)) \
	sh -c 'daemon_root="$$1"; \
	"$$daemon_root"/bin/guix-gd-daemon \
	"$$GUIX_GD_DEV_ROOT/var/guix/daemon-socket/socket" \
	"$$GUIX_GD_DEV_SOCK" \
	| tee daemon.log' \
	sh "$$($(GUIX_DAEMON_DEV))"

container/regular/start:
	sudo $$($(CONFIG_DEV_ENV)) \
	GUIX_GD_DEV_ROOT=$(TEST_REGULAR_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_REGULAR_SOCK) \
	sh ./env/dev/guix-gd/contain-overlayfs.sh

container/relay/start:
	sudo $$($(CONFIG_DEV_ENV)) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_RELAY_SOCK) \
	sh ./env/dev/guix-gd/contain-overlayfs.sh

daemon-fallback/regular/start:
	$(GUIX_TM) -- shell -- \
	sudo $$($(CONFIG_DEV_ENV)) \
	GUIX_GD_DEV_ROOT=$(TEST_REGULAR_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_REGULAR_SOCK) \
	GUIX_GD_DAEMON_ARGS='--disable-deduplication' \
	sh ./env/dev/guix-gd/start-daemon.sh

daemon-fallback/relay/start:
	$(GUIX_TM) -- shell -- \
	sudo $$($(CONFIG_DEV_ENV)) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_RELAY_SOCK) \
	GUIX_GD_DAEMON_ARGS='--disable-deduplication' \
	sh ./env/dev/guix-gd/start-daemon.sh

daemon/relay/start:
	sudo env $$($(CONFIG_DEV_ENV)) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	GUIX_GD_DEV_SOCK=$(TEST_RELAY_SOCK) \
	sh -c 'daemon_root="$$1"; \
	"$$daemon_root"/bin/guix-gd-daemon \
	"$(TEST_RELAY_ROOT)/var/guix/daemon-socket/socket" \
	"$(TEST_RELAY_SOCK)" \
	| tee daemon-relay.log' \
	sh "$$($(GUIX_DAEMON_DEV))"

container/shell:
	$(GUIX_TM) -- shell -- \
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/start-shell.sh


container/regular/stop:
	sudo $$($(CONFIG_DEV_ENV)) \
	GUIX_GD_DEV_ROOT=$(TEST_REGULAR_ROOT) \
	sh ./env/dev/guix-gd/kill-overlayfs.sh

container/relay/stop:
	sudo $$($(CONFIG_DEV_ENV)) \
	GUIX_GD_DEV_ROOT=$(TEST_RELAY_ROOT) \
	sh ./env/dev/guix-gd/kill-overlayfs.sh

container/stop:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/kill-overlayfs.sh

