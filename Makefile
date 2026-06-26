# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

CHANNELS            := './env/guix/channels.scm'

GUIX_TM             := guix time-machine --channels=$(CHANNELS)

GUILE_DEV           := $(GUIX_TM) \
                       -- shell guile guile-ares-rs --pure --preserve=.*LANG.* \
                       -- guile -L './src/gxd' \
                                -L './tests/gxd' \
                                -L './dev/gxd'
.PHONY: ares
ares:
	$(GUILE_DEV)  -c "((@ (ares server) run-nrepl-server))"

.PHONY: testbox/start
testbox/start:
	sh ./env/dev/testbox-start.sh




