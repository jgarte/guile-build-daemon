;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd prelude)
  #:export (comment))

;; taken from guile-ares-rs/src/guile/ares/guile/prelude.scm
(define-syntax comment
  (lambda (stx)
    "Ignores all the forms and just returns a @code{#<unspecified>}.  It's
helpful to prevent the evaluation of expressions, while keeping them
around."
    *unspecified*))

(comment
 "doesn't eval on module eval")
