;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build sandbox)
  #:use-module (gxd prelude)
  #:use-module ((gnu build accounts)
                #:select (password-entry group-entry write-passwd write-group))
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:export (prepare-sandbox-root!))

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
