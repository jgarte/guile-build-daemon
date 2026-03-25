# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

GUIXTM=guix time-machine -C ./env/guix/guix-gd/channels.scm
GUILE=$(GUIXTM) -- shell guile guile-ares-rs --pure --preserve=.*LANG.* -- guile
GUILE_DEV=${GUILE} -L ./src/guix-daemon -L ./tests/guix-daemon -L ./dev/guix-daemon

ares:
	${GUILE_DEV} -c \
	"((@ (ares server) run-nrepl-server))"
