;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd env guix packages)
  #:use-module (gnu packages)
  #:use-module (gnu packages guile-xyz)
  #:use-module (gxd env guix channels)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (rde packages guix)
  #:export (dev-env
            guix-package))

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
              '("guile"))))
