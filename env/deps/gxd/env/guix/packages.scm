;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd env guix packages)
  #:use-module ((gnu packages)
                #:select (specification->package))
  #:use-module ((gnu packages guile-xyz)
                #:select (guile-ares-rs))
  #:use-module ((gnu packages package-management)
                #:select (guix))
  #:use-module ((guix channels)
                #:select (channel-commit channel-name))
  #:use-module ((guix gexp)
                #:select (gexp))
  #:use-module ((guix git)
                #:select (git-checkout))
  #:use-module ((guix git-download)
                #:select (git-fetch
                          git-file-name
                          git-reference))
  #:use-module ((guix packages)
                #:select (base32
                          origin
                          package
                          package-arguments
                          package-version))
  #:use-module ((guix utils)
                #:select (substitute-keyword-arguments))
  #:use-module ((srfi srfi-1)
                #:select (filter))
  #:use-module ((gxd env guix channels)
                #:select (core-channels))
  #:export (dev-env
            guix-package))

;; from https://git.sr.ht/~abcdw/rde/tree/47fb718f/item/src/rde/packages/guix.scm
(define (get-guix-channel channels)
  (car
   (filter (lambda (x) (equal? (channel-name x) 'guix)) channels)))

;; from https://git.sr.ht/~abcdw/rde/tree/47fb718f/item/src/rde/packages/guix.scm
(define (make-guix-package channels)
  (let ((commit (channel-commit (get-guix-channel channels))))
    (package
      (inherit guix)
      (version
       (string-append (car (string-split (package-version guix) #\-))
                      "-" (string-take commit 7)))
      (source
       (git-checkout
        (url "https://git.guix.gnu.org/guix.git")
        (commit commit)))
      (arguments
       (substitute-keyword-arguments (package-arguments guix)
         ((#:tests? _)
          #f)
         ((#:phases phases)
          #~(modify-phases #$phases (delete 'check)))
         ((#:configure-flags flags #~'())
          #~(append
             #$flags
             (list
              #$(string-append "--with-channel-commit=" commit)))))))))

(define guix-package
  (make-guix-package core-channels))

;; The `guile-ares-rs' of the pinned Guix is 0.9.7, which predates the
;; suitbl context-binding syntax, checks and fixtures.
(define-public guile-ares-rs-latest
  (package
    (inherit guile-ares-rs)
    (version "0.9.8")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
              (url "https://git.sr.ht/~abcdw/guile-ares-rs")
              (commit version)))
       (file-name (git-file-name "guile-ares-rs" version))
       (sha256
        (base32
         "1fkd7j3ivs87z41hgf6wm9f5awp816viadm1gdr8ph9zmhb688c0"))))))

(define dev-env
  (cons* guix-package
         guile-ares-rs-latest
         (map specification->package
              '("util-linux"            ; mount, etc. kernel utils
                "coreutils"             ; env, chown, ect. POSIX utils
                "btrfs-progs"           ; mkfs.btrfs, etc.
                "bash-minimal"          ; sh, bash
                "tar" "gzip"
                "git-minimal"
                "guile"))))
