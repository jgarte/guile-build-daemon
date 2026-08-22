;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd test-prelude)
  #:export (capture-exception
            with-module-binding
            with-module-bindings))

(define (with-module-bindings module bindings proc)
  "Call PROC with BINDINGS installed in MODULE, then restore prior values.
BINDINGS is an alist of names to temporary values."
  (define (install! bindings)
    (for-each (lambda (binding)
                (module-set! module (car binding) (cdr binding)))
              bindings))
  (define saved
    (map (lambda (binding)
           (cons (car binding) (module-ref module (car binding))))
         bindings))
  (dynamic-wind
    (lambda () (install! bindings))
    proc
    (lambda () (install! (reverse saved)))))

(define (with-module-binding module name value proc)
  "Call PROC with NAME bound to VALUE in MODULE, then restore its prior value."
  (with-module-bindings module (list (cons name value)) proc))

(define (capture-exception thunk)
  "Return the exception THUNK raises, or #f when it returns normally."
  (with-exception-handler
      (lambda (exception) exception)
    (lambda () (thunk) #f)
    #:unwind? #t))
