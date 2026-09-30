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

## Prerequisites

### User and group subordinate IDs

The tests run programs under several identities inside a user namespace, so your
user needs at least two subordinate IDs delegated in `/etc/subuid` and
`/etc/subgid`.  See `subuid(5)` and `user_namespaces(7)`.

Mapping more than a single ID also needs the setuid-root `newuidmap` and
`newgidmap` helpers, which the `shadow` package provides.

If you are on Guix system you can add the following to your guix system config
to add subordinate IDs:

``` scheme
(use-modules
 (gnu)
 (gnu system shadow)     ; Provides 'subids-service-type'
 (gnu system accounts)  ; Provides 'subid-range'
 ...)

(operating-system
 ...
 (services
  (list
   (service subids-service-type
            (subids-configuration
             ;; user ranges
             (subuids (list (subid-range (name "user")
                                         (start 100000)
                                         (count 65536))))
             ;; group ranges
             (subgids (list (subid-range (name "user")
                                         (start 100000)
                                         (count 65536)))))))))
```


### Testbox disk

Initialize and mount the testbox disk before running `make check` or starting
Ares:

  make testbox-disk/init


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
