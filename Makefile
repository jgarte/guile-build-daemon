# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andrew Tropin

include .envrc

GUIXTM=./env/guix/time-machine
GUIX=$(GUIXTM) --
DEV_ENV_LOAD_PATH=-L ./env/guix -L ./env/deps
DEV_ENV=$(GUIX) shell \
	${DEV_ENV_LOAD_PATH} \
	-e '(@ (gxd env guix packages) dev-env)' \
	--pure --preserve=.*LANG.* --preserve=^TESTBOX_BTRFS --
GUILE=$(DEV_ENV) guile

GXD_SRC_LOAD_PATH=-L ./src/guile
TEST_SRC_LOAD_PATH=${GXD_SRC_LOAD_PATH} -L ./test/guile
DEV_SRC_LOAD_PATH=${TEST_SRC_LOAD_PATH} -L ./dev/guile

GUILE_DEV=${GUILE} ${DEV_SRC_LOAD_PATH}

.PHONY: ares check

ares:
	${GUILE_DEV} -c \
	"((@ (ares server) run-nrepl-server))"

check:
	${DEV_ENV} ares-suitbl -- ${TEST_SRC_LOAD_PATH}
