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

GUIX_GD_USER        := GUILE_LOAD_PATH=$(GUILE_LOAD_PATH_DEV) \
                       guile -c "(display (@ (guix-gd config) guix-gd-user))"
GUIX_GD_GROUP       := GUILE_LOAD_PATH=$(GUILE_LOAD_PATH_DEV) \
                       guile -c "(display (@ (guix-gd config) guix-gd-group))"
GUIX_GD_ROOT        := GUILE_LOAD_PATH=$(GUILE_LOAD_PATH_DEV) \
                       guile -c "(display (@ (guix-gd config) guix-gd-root))"

GUIX_DEV_PKG        := "(@ (guix-gd packages) guix-gd-fallback)"
# this should be reproducible with the same the channels.scm and config.scm
# commit: c8985dd911c4c8e2948c888df8b54c9bc317625e
GUIX_DEV_OUT        := '/gnu/store/dp204ijisfl4mm2vl7dxq866hx3v8fmh-guix-gd-fallback-1.5.0-c8985dd'


# shell with dev guix daemon available
GUIX_DEV_SHELL      := $(GUIX_TM) -- shell $(GUIX_LOAD_PATH_ENV) --expression=$(GUIX_DEV_PKG)

# for tests
STAGE0_POSIX_PKG    := "(@@ (gnu packages commencement) stage0-posix)"
STAGE0_POSIX_OUT    := '/guix-gd-root/gnu/store/nhh1vznrvl1q3jyjz6cf3j8jyqd5fvhj-stage0-posix-1.6.0'


ares:
	$(GUILE_DEV) -c "((@ (ares server) run-nrepl-server))"

build-dev-guix:
	$(GUIX_TM) -- build $(GUIX_LOAD_PATH_ENV) --no-grafts --expression=$(GUIX_DEV_PKG)

init-dev-guix-as-root:
	sudo GUIX_GD_ROOT=$$($(GUIX_GD_ROOT)) \
	     GUIX_GD_GROUP=$$($(GUIX_GD_GROUP)) \
	sh ./env/dev/guix-gd/init-guix-as-root.sh

init-dev-guix-unprivileged:
	sudo GUIX_GD_ROOT=$$($(GUIX_GD_ROOT)) \
	     GUIX_GD_USER=$$($(GUIX_GD_USER)) \
	sh ./env/dev/guix-gd/init-guix-unprivileged.sh

start-daemon-as-root:
	$(GUIX_DEV_SHELL) -- sudo guix-gd-fallback-daemon-as-root

# when running as unprivileged with `--build-users-group` flag it attempts to do root stuff
start-daemon-unprivileged:
	$(GUIX_DEV_SHELL) -- sudo -u $$($(GUIX_GD_USER)) guix-gd-fallback-daemon-unprivileged

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
