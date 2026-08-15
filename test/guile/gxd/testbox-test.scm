;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd testbox-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
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
