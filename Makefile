# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

GUIX_CHANNELS_FILE = ./env/guix/gxd/env/guix/channels.scm

# Guix requires `--unsafe-channel-evaluation' flag (UCE_FLAG) if the file that
# provides channels is not a simple list and needs to be evaluated; the older
# version of Guix does not accept this flag and will fail if it is set
GUIX_UCE_FLAG := $(shell \
                   guix time-machine --help 2>&1 | \
                   grep -q -- --unsafe-channel-evaluation && \
                   echo "--unsafe-channel-evaluation" \
                   )

GUIXTM := guix time-machine $(GUIX_UCE_FLAG) --channels=${GUIX_CHANNELS_FILE}
GUIX=$(GUIXTM) --

DEV_ENV_LOAD_PATH=-L ./env/guix -L ./env/deps
DEV_ENV=$(GUIX) shell \
       ${DEV_ENV_LOAD_PATH} \
       -e '(@ (gxd env guix packages) dev-env)' \
       --pure --preserve=.*LANG.* --
GUILE=$(DEV_ENV) guile

GXD_SRC_LOAD_PATH=-L ./src/guile
TEST_SRC_LOAD_PATH=${GXD_SRC_LOAD_PATH} -L ./test/guile
DEV_SRC_LOAD_PATH=${TEST_SRC_LOAD_PATH} -L ./dev/guile

GUILE_DEV=${GUILE} ${DEV_SRC_LOAD_PATH}

.PHONY: ares check

ares:
	${GUILE_DEV} -c "((@ (ares server) run-nrepl-server))"

check:
	${DEV_ENV} ares-suitbl -- ${TEST_SRC_LOAD_PATH}
