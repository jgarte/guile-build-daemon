# Guix Daemon (gxd)

A Guile implementation of a build daemon for Guix.

## Namespace

The name `gxd` is choosen as a namespace for the next Guix Daemon (aiming to be included to Guix v2.0) because it is:
- short
- ending on `d` as in `sshd`, `mpd`, etc.
- few name colisions in Guix/Linux namespaces
- 'rhymes' with the (legacy) C++ daemon `nix`
- sounds native :)

## Repository Structure

First level directories are the standard:
- src
- tests
- env
- dev

Second level directory is `gxd`. It used as a name-space for guile modules to avoid name collisions.

In general try to keep directory structure simple and add more nesting as needed following principles described in [A Sane Directory Structure for Software Project](https://trop.in/blog/a-sane-directory-structure-for-software-projects) blog post by Andrew Tropin.

## Development

Workflow fo interactive Guile development

Start the Guile nREPL server:

```sh
make ares
```

If you edit .scm files in Emacs run `M-x arei` to connect current buffer to nREPL server.

## Contributing

Commit is small digestible chunks.

This project uses conventional commit messages:
https://www.conventionalcommits.org

