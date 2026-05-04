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

GUIX_DAEMON_DEV_PKG := "(@ (guix-gd packages) guix-gd-daemon)"
GUIX_DAEMON_DEV     := $(GUIX_TM) -- build $(GUIX_LOAD_PATH_ENV) \
                                     --no-grafts \
                                     --expression=$(GUIX_DAEMON_DEV_PKG)

ares:
	$(GUILE_DEV) -s './dev/guix-daemon/ares-safe.scm'


daemon/build:
	$(GUIX_DAEMON_DEV)


daemon/init-build-users:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/init-dev-build-users.sh

container/start:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/contain-overlayfs.sh

daemon-fallback/start:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/start-daemon.sh

daemon/start:
	sudo env $$($(CONFIG_DEV_ENV)) \
	sh -c '$$($(GUIX_DAEMON_DEV))/bin/guix-gd-daemon \
	$$GUIX_GD_DEV_ROOT/var/guix/daemon-socket/socket \
	$$GUIX_GD_DEV_SOCK \
	| tee daemon.log'

container/shell:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/start-shell.sh


container/stop:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/kill-overlayfs.sh

