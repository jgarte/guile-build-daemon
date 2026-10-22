;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd test-prelude)
  #:use-module ((ice-9 exceptions)
                #:select (raise-exception with-exception-handler))
  #:use-module ((ice-9 match) #:select (match match-let))
  #:use-module ((ice-9 rdelim) #:select (read-string))
  #:use-module ((guix build utils) #:select (which))
  #:use-module ((gxd isolation) #:select (child-proc))
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module (gxd prelude)
  #:export (call-with-process-deadline
            capture-exception
            deadline
            require-program
            select-keys
            slurp
            spit
            with-module-binding))

(eval-when (eval load compile)
  (module-use! (module-public-interface (current-module))
               (resolve-interface '(gxd prelude))))

(define (select-keys alist keys)
  "Return ALIST's entries for KEYS in key order, omitting absent keys."
  (filter-map (lambda (key) (assoc key alist)) keys))

(define (require-program program)
  "Return the complete file name of PROGRAM on $PATH, or raise an error."
  (or (which program)
      (error "unable to find program" program)))

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

(define-syntax-rule (deadline seconds body ...)
  (call-with-process-deadline seconds (lambda () body ...)))

(define (call-with-process-deadline seconds thunk)
  "Call THUNK in a child, returning its small readable value.
Raise on child failure or after SECONDS; disconnect and reap before returning.
The value must fit in the child channel's buffer without a concurrent reader."
  (match-let (((pid _ <= disconnect!)
               (child-proc SIGCHLD (lambda (=> _) (=> 'result (thunk))))))
    (let ((deadline (+ seconds (current-time)))
          (reaped? #f))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (let wait ()
            (match (waitpid pid WNOHANG)
              ((0 . _)
               (when (>= (current-time) deadline)
                 (error "process deadline exceeded"))
               (usleep 10000)
               (wait))
              ((_ . status)
               (set! reaped? #t)
               (unless (equal? 0 (status:exit-val status))
                 (error "process failed" status))
               (<= 'result)))))
        (lambda ()
          (let* ((disconnect-error (capture-exception (lambda () (disconnect!))))
                 (reap-error
                  (capture-exception
                   (lambda ()
                     (unless reaped?
                       (kill pid SIGKILL)
                       (waitpid pid))))))
            (when (or disconnect-error reap-error)
              (raise-exception (or disconnect-error reap-error)))))))))
