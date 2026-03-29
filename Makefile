# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

CHANNELS            := './env/guix/guix-gd/channels.scm'

LOAD_PATH_CODE      := --load-path='./src/guix-daemon' \
                       --load-path='./tests/guix-daemon' \
                       --load-path='./dev/guix-daemon'

LOAD_PATH_ENV       := --load-path='./env/dev' \
                       --load-path='./env/guix'

GUILE_LOAD_PATH_DEV := "$$(cd ./env/dev && pwd):$$GUILE_LOAD_PATH"

GUIX_TM             := guix time-machine --channels=$(CHANNELS)

GUILE               := $(GUIX_TM) -- shell guile guile-ares-rs --pure --preserve=.*LANG.* -- guile
GUILE_DEV           := $(GUILE) $(LOAD_PATH_CODE)

GUIX_DEV_PKG        := "(@ (guix-gd packages) guix-gd-fallback)"
GUIX_DEV_OUT        := '/gnu/store/0vb03nxks58byg2wi1vcbfkm6z346yn6-guix-gd-fallback-1.5.0-c8985dd'
# shell with dev guix daemon available
GUIX_DEV_SHELL      := $(GUIX_TM) -- shell $(LOAD_PATH_ENV) --expression=$(GUIX_DEV_PKG)


ares:
	$(GUILE_DEV) -c "((@ (ares server) run-nrepl-server))"

build-dev-guix:
	$(GUIX_TM) -- build $(LOAD_PATH_ENV) --expression=$(GUIX_DEV_PKG)

init-dev-guix-as-root:
	sudo GUILE_LOAD_PATH=$(GUILE_LOAD_PATH_DEV) sh ./env/dev/guix-gd/init-guix-as-root.sh

init-dev-guix-unprivileged:
	sudo GUILE_LOAD_PATH=$(GUILE_LOAD_PATH_DEV) sh ./env/dev/guix-gd/init-guix-unprivileged.sh

start-daemon:
	 $(GUIX_DEV_SHELL) -- sudo guix-gd-fallback-daemon

# This target prints the path and checks if it matches a "known good" hash
check-dev-guix:
	@echo "Checking Dev Guix reproducibility..."
	@STORE_PATH=$$($(GUIX_TM) -- build $(LOAD_PATH_ENV) --expression=$(GUIX_DEV_PKG)); \
	echo "Result: $$STORE_PATH"; \
	diff <(echo $(GUIX_DEV_OUT)) <(echo $$STORE_PATH) || (echo "FAILED: Path mismatch!" && exit 1);
