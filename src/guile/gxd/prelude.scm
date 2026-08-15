;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd prelude)
  #:export (comment get get-in))

;; taken from guile-ares-rs/src/guile/ares/guile/prelude.scm
(define-syntax comment
  (lambda (stx)
    "Ignores all the forms and just returns a @code{#<unspecified>}.  It's
helpful to prevent the evaluation of expressions, while keeping them
around."
    *unspecified*))

(comment
 "doesn't eval on module eval")

(define (get alist key)
  "Return the value KEY is associated with in ALIST, or #f."
  (assq-ref alist key))

(define (get-in alist path)
  "Return the value ALIST holds under PATH, or #f if there is none."
  (let loop ((value alist) (path path))
    (cond ((null? path) value)
          ((not (pair? value)) #f)
          (else (loop (assq-ref value (car path)) (cdr path))))))
