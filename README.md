# Guix Build Daemon

A Guile implementation of a build daemon for Guix.

## Getting Started

Start the nREPL server:

  make ares

## Differential daemon test

This test runs the same Guix command in two separate overlayfs containers:

1. **regular** container → talks directly to fallback `guix-daemon`.
2. **relay** container → talks to `guix-gd-daemon` relay.

Then it compares:

- exit code
- stdout
- stderr
- filesystem delta (`gnu/store-upper`, `var/guix`, `etc/guix`)

Two containers remove the need for any "reset state" command between runs.

Prerequisites (start each in its own terminal):

  make container/regular/start
  make daemon-fallback/regular/start

  make container/relay/start
  make daemon-fallback/relay/start
  make daemon/relay/start

Before running the test, authenticate once for `sudo`:

  sudo -v

Run test:

  make test/differential

Main environment variables:

- `GUIX_GD_TEST_COMMAND` (default: `guix gc --list-roots`)
- `GUIX_GD_TEST_ARTIFACTS_DIR` (default: `tmp/daemon-differential`)
- `GUIX_GD_TEST_EXPECT_EXIT` (default: `0`)

Regular scenario:

- `GUIX_GD_TEST_REGULAR_ROOT` (default: `/guix-gd-overlayfs-regular`)
- `GUIX_GD_TEST_REGULAR_CONTAINER_PID` (optional)
- `GUIX_GD_TEST_REGULAR_SOCKET` (default: `/tmp/guix-gd-fallback-regular.sock`)

Relay scenario:

- `GUIX_GD_TEST_RELAY_ROOT` (default: `/guix-gd-overlayfs-relay`)
- `GUIX_GD_TEST_RELAY_CONTAINER_PID` (optional)
- `GUIX_GD_TEST_RELAY_SOCKET` (default: `/var/guix/daemon-socket/socket`)
- `GUIX_GD_TEST_RELAY_SOCKET_HOST` (default: `<relay-root>/var/guix/daemon-socket/socket`)
- `GUIX_GD_TEST_RELAY_FALLBACK_SOCKET` (default: `/tmp/guix-gd-fallback-relay.sock`)

Artifacts and summary report are written to `tmp/daemon-differential/`.

Stop containers when done:

  make container/regular/stop
  make container/relay/stop

## Contributing

This project uses conventional commit messages:
https://www.conventionalcommits.org
