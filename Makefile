# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

GUIXTM=guix time-machine -C ./env/guix/channels.scm
GUILE=$(GUIXTM) -- shell --load-path='./env/guile' --manifest='./env/guile/gxd/manifest.scm' --pure --preserve=.*LANG.* -- guile
GUILE_DEV=${GUILE} -L ./src/guile -L ./tests/guile -L ./dev/guile

ares:
	${GUILE_DEV} -c \
	"((@ (ares server) run-nrepl-server))"
