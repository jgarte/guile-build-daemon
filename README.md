# Guix Build Daemon

A Guile implementation of a build daemon for Guix.

## Getting Started

Start the nREPL server:

  make ares

## Differential daemon test

This test runs one Guix command twice inside the same overlayfs container:

1. Directly against fallback `guix-daemon` socket.
2. Through `guix-gd-daemon` relay socket.

Then it compares:

- exit code
- stdout
- stderr
- filesystem delta (`gnu/store-upper`, `var/guix`, `etc/guix`)

Prerequisite (in separate terminals):

  make container/start
  make daemon-fallback/start
  make daemon/start

Before running the test, authenticate once for `sudo`:

  sudo -v

Run test:

  make test/differential

Main environment variables:

- `GUIX_GD_TEST_COMMAND` (default: `guix gc --list-roots`)
- `GUIX_GD_TEST_FALLBACK_SOCKET` (default: `/tmp/guix-gd-fallback.sock`)
- `GUIX_GD_TEST_RELAY_SOCKET` (default: `/var/guix/daemon-socket/socket`)
- `GUIX_GD_TEST_ARTIFACTS_DIR` (default: `tmp/daemon-differential`)
- `GUIX_GD_TEST_EXPECT_EXIT` (default: `0`)
- `GUIX_GD_TEST_RESET_COMMAND` (optional command run between the two scenarios)

Artifacts and summary report are written to `tmp/daemon-differential/`.

Stop container namespace when done:

  make container/stop

## Contributing

This project uses conventional commit messages:
https://www.conventionalcommits.org
