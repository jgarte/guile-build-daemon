# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

CHANNELS       := './env/guix/guix-gd/channels.scm'

LOAD_PATH_CODE := --load-path='./src/guix-daemon' \
                  --load-path='./tests/guix-daemon' \
                  --load-path='./dev/guix-daemon'

LOAD_PATH_ENV  := --load-path='./env/dev' \
                  --load-path='./env/guix'

GUIX_TM        := guix time-machine --channels=$(CHANNELS)

GUILE          := $(GUIX_TM) -- shell guile guile-ares-rs --pure --preserve=.*LANG.* -- guile
GUILE_DEV      := $(GUILE) $(LOAD_PATH_CODE)

GUIX_DEV_PKG   := '(@ (guix-gd packages) guix-gd-fallback)'
GUIX_DEV_SHELL := $(GUIX_TM) -- shell $(LOAD_PATH_ENV) --expression=$(GUIX_DEV_PKG)


ares:
	$(GUILE_DEV) -c "((@ (ares server) run-nrepl-server))"

build-dev-guix:
	$(GUIX_TM) -- build $(LOAD_PATH_ENV) --expression=$(GUIX_DEV_PKG)

init-dev-guix:
	sh ./env/dev/guix-gd/init-guix-root-and-users.sh

start-daemon:
	 $(GUIX_DEV_SHELL) -- sudo guix-gd-fallback-daemon
