;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd testbox-test)
  #:use-module ((ice-9 exceptions)
                #:select (exception-args
                          exception-kind
                          make-exception-with-message))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd test-prelude)
                #:select (capture-exception with-module-binding))
  #:use-module ((gxd testbox)
                #:select (make-testbox-manifest
                          start-testbox
                          teardown-testbox!
                          testbox-pid1)))

(define (namespace-id pid name)
  "Return the identifier of PID's NAME namespace, which two processes share
exactly when they are in the same one."
  (readlink (format #f "/proc/~a/ns/~a" pid name)))

(define (call-with-testbox proc)
  (let ((box (start-testbox (make-testbox-manifest))))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc box))
      (lambda () (teardown-testbox! box)))))

(define (reaped? pid)
  "Return #t when PID has been collected already.  Waiting on such a pid
fails with ECHILD, which is what distinguishes it from one still running."
  (with-exception-handler
      (lambda (exception)
        (match (cons (exception-kind exception) (exception-args exception))
          (('system-error _ _ _ (errno)) (= errno ECHILD))
          (_ #f)))
    (lambda ()
      (waitpid pid WNOHANG)
      #f)
    #:unwind? #t))

(define (alive? pid)
  "Return #t when PID can be signalled, and so has not been reaped."
  (with-exception-handler
      (lambda (_) #f)
    (lambda ()
      (kill pid 0)
      #t)
    #:unwind? #t))

(define-suite (testbox-tests)
  (test "testbox enters fresh user, mount, and pid namespaces" ()
    (call-with-testbox
     (lambda (box)
       (define (fresh? name)
         (not (string=? (namespace-id (testbox-pid1 box) name)
                        (namespace-id (getpid) name))))

       (is (fresh? 'user))
       (is (fresh? 'mnt))
       (is (fresh? 'pid))))))
