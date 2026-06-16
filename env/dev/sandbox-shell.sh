#!/bin/sh
nsenter --target $1 \
        --preserve-credentials \
        --user \
        --env \
        --mount \
        bash --login
