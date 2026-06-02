# Guix Guile Daemon

A Guile implementation of a build daemon for Guix.

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
