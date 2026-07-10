# Glossary

The terms `derivation`, `store`, (build) `daemon`, `client` and
(client-daemon) `socket` are the core concepts and components of Guix.
Those are defined in [GNU Guix Reference
Manual](https://guix.gnu.org/manual/devel/en/guix.html).

The terms for the new (sub-)components introduced in the current project
are defined below.

To distinguish between the current (old/legacy) and the next (guile)
implementation of Guix Daemon (presumably to be included in Guix v2.0) we refer
to the former as `nixd` (legacy `nix-daemon`) and the later as `gxd` (ala native
`guix-daemon` in guile).

`nixd` - (legacy) C++ daemon ported from [nix package
manager](https://github.com/NixOS/nix). Its source code lives in the `./nix`
directory of Guix repository.

`gxd` - Guile implementation of Guix Daemon. Unified implementation language
makes it the native daemon. `gxd` also used as the current project's namespace.

`fbd` (stands for `fallback-nix-daemon`) - the `nixd`
process that is used as a fallback for operations that are not yet
implemented in `gxd`.

`relay` - a separate program or a guile module that listens on two sockets and
relays RPCs from one socket to anthother in both directions, parses and logs the
messages.

`testbox` - mount and user namespace isolated environment for testing
and logging guix client/daemon interactions. Mount namespace provides a
clean filesystem for inspecting changes in daemon's artifacts and guix
state without modifying the state of host system. The user namespace
emulates daemon and client users.

`nixd-testbox` - an isolated environment with running `nixd` that communicates
with the `client` via logging `relay`

`gxd-testbox` - an isolated environment with running `gxd` and running `fbd`
(`fallback-nix-daemon`) via logging `relay` to.

`differential-test` (`diff-test`) - test suites based on comparing logs
and artifacts of `nixd-testbox` and `gxd-testbox` to ensure the backward
compatibility of new implementation of guix daemon (`gxd`)
