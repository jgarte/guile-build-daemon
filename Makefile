# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

GUIXTM=guix time-machine -C ./env/guix/channels.scm
GUILE=$(GUIXTM) -- shell guile guile-ares-rs --pure --preserve=.*LANG.* -- guile
GUILE_DEV=${GUILE} -L ./src/gxd -L ./tests/gxd -L ./dev/gxd

ares:
	${GUILE_DEV} -c \
	"((@ (ares server) run-nrepl-server))"
