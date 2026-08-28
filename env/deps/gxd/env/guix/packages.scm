;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd env guix packages)
  #:use-module (gnu packages)
  #:use-module (gnu packages guile-xyz)
  #:use-module (gnu packages package-management) ; For the base 'guix' package variable
  
  #:use-module (guix git-download)
  #:use-module (guix packages)               ; package, package-version, package-arguments
  #:use-module (guix channels)               ; channel-name and channel-commit
  #:use-module (guix git)                    ; git-checkout
  #:use-module (guix utils)                  ; substitute-keyword-arguments
  #:use-module (guix gexp)
  #:use-module (srfi srfi-1)                 ; filter
  #:use-module (gxd env guix channels)
  #:export (dev-env
            guix-package))

;; from https://git.sr.ht/~abcdw/rde/tree/master/item/src/rde/src/rde/packages/guix.scm@47fb718f
(define (get-guix-channel channels)
  (car
   (filter (lambda (x) (equal? (channel-name x) 'guix)) channels)))

;; from https://git.sr.ht/~abcdw/rde/tree/master/item/src/rde/src/rde/packages/guix.scm@47fb718f
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
;; suitbl context-binding syntax and the (ares suitbl checks) module.
(define-public guile-ares-rs-latest
  (let ((commit "5b4908c2786e5b65e3267691e21aedd98eb2f464")
        (revision "0"))
    (package
      (inherit guile-ares-rs)
      (version (git-version "0.9.7" revision commit))
      (source
       (origin
         (method git-fetch)
         (uri (git-reference
               (url "https://git.sr.ht/~abcdw/guile-ares-rs")
               (commit commit)))
         (file-name (git-file-name "guile-ares-rs" version))
         (sha256
          (base32
           "1pj03akd9v2v02r7389m246ppkkhiw8g9z87qm5g9nsm35vckyd7")))))))

(define dev-env
  (cons* guix-package
         guile-ares-rs-latest
         (map specification->package
              '("util-linux"            ; mount, etc. kernel utils
                "coreutils"             ; env, chown, ect. POSIX utils
                "btrfs-progs"           ; mkfs.btrfs, etc.
                "bash-minimal"          ; sh, bash
                "guile"))))
