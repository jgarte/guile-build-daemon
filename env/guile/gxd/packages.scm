;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd packages)
  #:use-module (gnu packages guile-xyz)
  #:use-module (guix git-download)
  #:use-module (guix packages))

;; The `guile-ares-rs' of the pinned Guix is 0.9.7, which predates the
;; suitbl context-binding syntax and the (ares suitbl checks) module.
(define-public guile-ares-rs-latest
  (let ((commit "27b2f2cfeaca38171347730d8dfc9951cf417f72")
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
           "1vs7wwlr4f8dndjhsa1iz36r8sszawjgll4kggfx7ly78zalj4lm")))))))
