;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd test-prelude)
  #:use-module ((ice-9 rdelim) #:select (read-string))
  #:use-module (gxd prelude)
  #:export (capture-exception
            slurp
            spit
            with-module-binding))

(eval-when (eval load compile)
  (module-use! (module-public-interface (current-module))
               (resolve-interface '(gxd prelude))))

(define (slurp input)
  "Return all text from INPUT, a file name or seekable port."
  (if (port? input)
      (begin
        (seek input 0 SEEK_SET)
        (read-string input))
      (call-with-input-file input read-string)))

(define (spit file content)
  "Replace FILE with CONTENT."
  (with-output-to-file file (lambda () (display content))))

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
