# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin
# SPDX-FileCopyrightText: 2026 Andrew Zhurov
# SPDX-FileCopyrightText: 2026 buttonspresser


GUIX_CHANNELS_FILE = ./env/guix/gxd/env/guix/channels.scm

# Guix requires `--unsafe-channel-evaluation' flag (UCE_FLAG) if the file that
# provides channels is not a simple list and needs to be evaluated; the older
# version of Guix does not accept this flag and will fail if it is set
GUIX_UCE_FLAG := $(shell \
                   guix time-machine --help 2>&1 | \
                   grep -q -- --unsafe-channel-evaluation && \
                   echo "--unsafe-channel-evaluation" \
                   )

GUIX_TM := guix time-machine $(GUIX_UCE_FLAG) --channels=${GUIX_CHANNELS_FILE}
GUIX = $(GUIX_TM) --

# Guile Load Paths (GLP)
GLP_DEV_ENV = -L ./env/guix \
              -L ./env/deps
GLP_GXD     = -L ./src/guile
GLP_TEST    = -L ./test/guile ${GLP_GXD}
GLP_DEV     = -L ./dev/guile ${GLP_TEST}

DEV_ENV = $(GUIX) shell ${GLP_DEV_ENV} \
          -e '(@ (gxd env guix packages) dev-env)' \
          --pure --preserve=.*LANG.* --
GUILE_DEV = $(DEV_ENV) guile ${GLP_DEV}

# ----------------------------------------------------------------------------

.PHONY: ares
ares:
	${GUILE_DEV} -c "((@ (ares server) run-nrepl-server))"

.PHONY: check
check:
	${DEV_ENV} ares-suitbl -- ${GLP_TEST}
