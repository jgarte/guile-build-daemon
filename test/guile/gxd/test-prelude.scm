;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd test-prelude)
  #:export (capture-exception
            with-module-binding))

(define (with-module-binding module name value proc)
  "Call PROC with NAME bound to VALUE in MODULE, restoring the previous
binding afterwards.  This replaces a binding other modules have already
imported, so a test can make a procedure fail where no seam exists."
  (let ((saved (module-ref module name)))
    (dynamic-wind
      (lambda () (module-set! module name value))
      proc
      (lambda () (module-set! module name saved)))))

(define (capture-exception thunk)
  "Return the exception THUNK raises, or #f when it returns normally."
  (with-exception-handler
      (lambda (exception) exception)
    (lambda () (thunk) #f)
    #:unwind? #t))
