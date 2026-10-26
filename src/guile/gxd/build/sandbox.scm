;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build sandbox)
  #:use-module (gxd prelude)
  #:use-module ((gxd isolation) #:select (bind-mount! bind-mount-read-only!))
  #:use-module ((gnu build accounts)
                #:select (password-entry group-entry write-passwd write-group))
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module ((guix build syscalls) #:select (mount))
  #:use-module ((ice-9 match) #:select (match-lambda))
  #:export (prepare-sandbox-root! mount-build-inputs! mount-build-devices!))

(define (write-root-file sandbox-root name contents)
  (define port (open-output-file (string-append sandbox-root name)))
  (call-with-cleanup
   (lambda () (close-port port))
   (lambda () (display contents port))))

(define (prepare-sandbox-root! sandbox-root store-directory uid gid)
  "Populate fresh SANDBOX-ROOT for an ordinary build by UID and GID.
Create writable /tmp and STORE-DIRECTORY, account and localhost files.
The caller owns SANDBOX-ROOT and its cleanup; no mounts are established."
  (define root-tmp (string-append sandbox-root "/tmp"))
  (define root-store (string-append sandbox-root store-directory))

  (mkdir-p root-tmp)
  (chmod root-tmp #o1777)

  (mkdir-p (string-append sandbox-root "/etc"))

  (write-passwd
   (list (password-entry
          (name "nixbld")
          (uid uid)
          (gid gid)
          (real-name "Nix build user")
          (directory "/")
          (shell "/noshell"))
         (password-entry
          (name "nobody")
          (uid 65534)
          (gid 65534)
          (real-name "Nobody")
          (directory "/")
          (shell "/noshell")))
   (string-append sandbox-root "/etc/passwd"))

  (write-group
   (list (group-entry
          (name "nixbld")
          (password "!")
          (gid gid)))
   (string-append sandbox-root "/etc/group"))

  (write-root-file sandbox-root "/etc/hosts" "127.0.0.1 localhost\n::1 localhost\n")

  (mkdir-p root-store)
  (chmod root-store #o1775))

(define (mount-build-inputs! sandbox-root input-paths)
  "Expose INPUT-PATHS read-only at their original paths beneath SANDBOX-ROOT.
SANDBOX-ROOT is the prepared host-side sandbox directory.  INPUT-PATHS is the
realized input closure, and mounts are private to the caller."
  (for-each (lambda (path)
              (bind-mount-read-only! path (string-append sandbox-root path)))
            input-paths))

(define (mount-build-devices! sandbox-root)
  "Install ordinary build devices beneath SANDBOX-ROOT in the caller's private mounts.
Bind available standard devices and mount private shared memory and, when
supported by the host, pseudo-terminals.  SANDBOX-ROOT is freshly prepared."
  (define dev (string-append sandbox-root "/dev"))
  (define shm (string-append dev "/shm"))
  (define pts (string-append dev "/pts"))

  ;; Expose selected host devices, not the host's entire /dev.
  (mkdir-p dev)
  (for-each
   (lambda (device)
     (when (file-exists? device)
       (bind-mount! device (string-append sandbox-root device))))
   '("/dev/full" "/dev/null" "/dev/random" "/dev/tty" "/dev/urandom" "/dev/zero"))

  ;; Resolve descriptor links through the builder's procfs.
  (for-each
   (match-lambda
     ((name . target) (symlink target (string-append dev "/" name))))
   '(("fd" . "/proc/self/fd")
     ("stdin" . "/proc/self/fd/0")
     ("stdout" . "/proc/self/fd/1")
     ("stderr" . "/proc/self/fd/2")))

  ;; Give builds private shared-memory storage.
  (mkdir-p shm)
  (mount "none" shm "tmpfs")

  ;; Allocate pseudo-terminals independently of the host's devpts instance.
  (when (file-exists? "/dev/pts/ptmx")
    (mkdir-p pts)
    (mount "none" pts "devpts" 0 "newinstance,mode=0620")
    (symlink "/dev/pts/ptmx" (string-append dev "/ptmx"))
    (chmod (string-append pts "/ptmx") #o666)))
