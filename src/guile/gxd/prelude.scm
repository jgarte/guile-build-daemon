;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd prelude)
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type make-exception
                          make-exception-with-message raise-exception with-exception-handler))
  #:use-module ((srfi srfi-2) #:select (and-let*))
  #:use-module ((srfi srfi-197) #:select (chain))
  #:re-export (and-let* chain)
  #:export (comment get get-in call-with-cleanup todo!
                    &todo todo? todo-feature todo-context))

(define-exception-type &todo &error
  make-todo todo?
  (feature todo-feature)
  (context todo-context))

(define (todo! feature . context)
  "Raise a not-yet-implemented error for planned FEATURE, carrying CONTEXT."
  (raise-exception
   (make-exception
    (make-todo feature context)
    (make-exception-with-message (string-append "not yet implemented: " feature)))))

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

(define (call-with-cleanup cleanup thunk)
  "Call THUNK, then CLEANUP, preserving THUNK's returned values.
On exception, call CLEANUP and re-raise the original exception even if cleanup
also fails.  Propagate cleanup failures after normal completion."
  (define results
    (with-exception-handler
      (lambda (exception)
        (false-if-exception (cleanup))
        (raise-exception exception))
      (lambda () (call-with-values thunk list))
      #:unwind? #t))

  (cleanup)
  (apply values results))

(define (get-in alist path)
  "Return the value ALIST holds under PATH, or #f if there is none."
  (let loop ((value alist) (path path))
    (cond ((null? path) value)
          ((not (pair? value)) #f)
          (else (loop (assq-ref value (car path)) (cdr path))))))
