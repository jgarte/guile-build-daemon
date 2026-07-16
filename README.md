# Guix Build Daemon

A Guile implementation of a build daemon for Guix.

## Project namespace

The `gxd` is used as a namespace for the next implementation of Guix
Daemon.

The rationale for `gxd` namespace:

- short and concise - makes a good prefix
- ends on `d` (daemon) as in `sshd`, `mpd`, etc.
- distinct - does not collide with other Guix/Linux namespaces
- 'rhymes' with the C++ `nix` daemon, but sounds native

## Getting Started

Start the nREPL server:

  make ares

## Contributing

This project uses Scoped Commits for commit messages format:
https://scopedcommits.com

```
<scope>: <description>
```

`<scope>` - the subsystem, area, or module that the commit touches
`<description>` - a short description of the changes made. Description
startrs with lower case.
