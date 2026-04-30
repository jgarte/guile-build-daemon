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
# /gnu/store/41v5i2lan6h4dgbjxql26i6jk3yyfzs6-guix-gd-daemon-0.1.0

GUIX_DEV_PKG        := "(@ (guix-gd packages) guix-gd-fallback)"
# this should be reproducible with the same the channels.scm and config.scm
# commit: c8985dd911c4c8e2948c888df8b54c9bc317625e
GUIX_DEV_OUT        := '/gnu/store/dp204ijisfl4mm2vl7dxq866hx3v8fmh-guix-gd-fallback-1.5.0-c8985dd'

# shell with dev guix daemon available
GUIX_DEV_SHELL      := $(GUIX_TM) -- shell $(GUIX_LOAD_PATH_ENV) \
                                           --expression=$(GUIX_DEV_PKG) \
                                           --expression=$(GUIX_DAEMON_DEV_PKG)

# for tests
STAGE0_POSIX_PKG    := "(@@ (gnu packages commencement) stage0-posix)"
STAGE0_POSIX_OUT    := '/guix-gd-root/gnu/store/nhh1vznrvl1q3jyjz6cf3j8jyqd5fvhj-stage0-posix-1.6.0'


ares:
	$(GUILE_DEV) -s './dev/guix-daemon/ares-safe.scm'

arei:
	$(GUIX_TM) \
	-- shell emacs-pgtk emacs-arei git --pure \
	-E '.*GTK.*|.*XDG.*|.*DISPLAY.*' \
	-- emacs -q

build-dev-guix:
	$(GUIX_TM) -- build $(GUIX_LOAD_PATH_ENV) --no-grafts --expression=$(GUIX_DEV_PKG)

build-dev-guix-gd-daemon:
	$(GUIX_DAEMON_DEV)


init-dev-build-users:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/init-dev-build-users.sh

start-container:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/contain-overlayfs.sh

start-fallback-daemon:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/start-daemon.sh

start-daemon:
	sudo env $$($(CONFIG_DEV_ENV)) \
	sh -c '$$($(GUIX_DAEMON_DEV))/bin/guix-gd-daemon \
	$$GUIX_GD_DEV_ROOT/var/guix/daemon-socket/socket \
	$$GUIX_GD_DEV_SOCK'


start-daemon-test:
	sudo env $$($(CONFIG_DEV_ENV)) \
	sh -c 'echo $$GUIX_GD_DEV_ROOT'

start-shell:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/start-shell.sh


kill-container:
	sudo $$($(CONFIG_DEV_ENV)) \
	sh ./env/dev/guix-gd/kill-overlayfs.sh


# shell with dev guix daemon available (isolated socket, store, var, etc..)
dev-shell:
	$(GUIX_DEV_SHELL)


# This target prints the path and checks if it matches a "known good" hash
check-dev-guix-build:
	@echo "Checking Dev Guix reproducibility..."
	@STORE_PATH=$$($(GUIX_TM) -- build $(GUIX_LOAD_PATH_ENV) --expression=$(GUIX_DEV_PKG)); \
	echo "Result: $$STORE_PATH"; \
	diff <(echo $(GUIX_DEV_OUT)) <(echo $$STORE_PATH) || (echo "FAILED: Path mismatch!" && exit 1);

check-dev-guix-stage0-posix:
	@echo "Checking reproducibility for stage0-posix..."
	$(MAKE) start-daemon-unprivileged
	@STORE_PATH=$$($(GUIX_DEV_SHELL) -- guix build -e $(STAGE0_POSIX_PKG) --no-substitutes); \
	echo "Result: $$STORE_PATH"; \
	diff <(echo $(STAGE0_POSIX_OUT)) <(echo $$STORE_PATH) || (echo "FAILED: Path mismatch!" && exit 1);
