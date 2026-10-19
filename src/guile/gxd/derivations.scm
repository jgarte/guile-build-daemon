;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd derivations)
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (read-derivation))
  #:export (read-derivation))

(define (read-derivation port)
  "Read a derivation from PORT without loading its input derivations.
Input records hold filenames under `derivation-input-derivation' until resolved.
Accept the syntax understood by Guix's reader; decoding errors propagate."
  (guix-drv:read-derivation port identity))
