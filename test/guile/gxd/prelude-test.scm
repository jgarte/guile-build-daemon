;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd prelude-test)
  #:use-module ((ice-9 exceptions)
                #:select (exception-args
                          exception-kind
                          with-exception-handler))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module (gxd test-prelude))

(define nested
  '((a . 1)
    (b . ((c . 2)
          (d . ((e . 3)))))))

(define (reaped? pid)
  (with-exception-handler
    (lambda (exception)
      (match (cons (exception-kind exception) (exception-args exception))
        (('system-error _ _ _ (errno)) (= errno ECHILD))
        (_ #f)))
    (lambda () (waitpid pid WNOHANG) #f)
    #:unwind? #t))

(define (timeout-facts)
  (call-with-temporary-directory
   (lambda (directory)
     (define pid-file (string-append directory "/pid"))
     (define failure
       (capture-exception
        (lambda ()
          (call-with-process-deadline
           1
           (lambda ()
             (call-with-output-file pid-file
               (lambda (port) (write (getpid) port)))
             (sleep 5))))))

     (list (not (not failure))
           (reaped? (call-with-input-file pid-file read))))))

(define-suite (process-deadline-tests)
  (test "bounded process execution returns or kills and reaps" ()
    (is (equal? '(value 1)
                (call-with-process-deadline
                 2 (lambda () '(value 1)))))
    (is (equal? '(#t #t) (timeout-facts)))))

(define-suite (get-tests)
  (test "get reads a key, or #f when it is absent" ()
    (is (= 1 (get nested 'a)))
    (is (eq? #f (get nested 'missing))))

  (test "get-in returns the value under a path" ()
    (is (= 2 (get-in nested '(b c))))
    (is (= 3 (get-in nested '(b d e))))
    (is (equal? nested (get-in nested '()))))

  (test "get-in returns #f when a path leads nowhere" ()
    (is (eq? #f (get-in nested '(missing))))
    (is (eq? #f (get-in nested '(b missing))))
    (is (eq? #f (get-in nested '(b d e missing))))
    (is (eq? #f (get-in nested '(a b))))))
