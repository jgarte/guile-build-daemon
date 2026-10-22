;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd builder-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd builder) #:select (execute-builder!))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((guix derivations)
                #:select (derivation-builder derivation-builder-arguments))
  #:use-module ((srfi srfi-9 gnu) #:select (set-fields))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((ice-9 exceptions)
                #:select (make-exception-with-message raise-exception))
  #:use-module ((rnrs bytevectors) #:select (make-bytevector bytevector=? bytevector-length))
  #:use-module ((rnrs io ports) #:select (open-bytevector-output-port put-bytevector))
  #:use-module ((srfi srfi-11) #:select (let-values)))

(define (builder-derivation expression)
  "Return a derivation running EXPRESSION with the test environment's Guile."
  (set-fields (empty-derivation)
    ((derivation-builder) (require-program "guile"))
    ((derivation-builder-arguments)
     (list "--no-auto-compile" "-c" (object->string expression)))))

(define-suite (builder-tests)
  (test "capture exactly the bytes written by the builder and preserve its exit code" ()
    (define expected-exit-code 7)
    (define expected-output (make-bytevector 300000 255))
    (define drv
      (builder-derivation
       `(begin
          (use-modules (rnrs bytevectors) (rnrs io ports))
          (put-bytevector (current-output-port) (make-bytevector 300000 255))
          (force-output)
          (exit ,expected-exit-code))))

    (define observations
      (deadline 5
        (let-values (((output captured-bytes) (open-bytevector-output-port)))
          (define status
            (execute-builder! drv "/store" "/tmp" 1
                              (lambda (bytes) (put-bytevector output bytes))))

          (list (bytevector=? expected-output (captured-bytes))
                (status:exit-val status)))))

    (match-let (((complete-output? exit-code) observations))
      (is complete-output?)
      (is (equal? expected-exit-code exit-code))))

  (test "report an error when the build directory does not exist" ()
    (define drv (builder-derivation '(exit 0)))
    (define observations
      (deadline 5
        (define log-called? #f)
        (define failure
          (capture-exception
           (lambda ()
             (execute-builder! drv "/store" "/missing-builder-directory" 1
                               (lambda (_) (set! log-called? #t))))))

        (list (not (not failure)) log-called?)))

    (match-let (((setup-rejected? log-called?) observations))
      (is setup-rejected?)
      (is (not log-called?))))

  (test "a missing executable produces a diagnostic and exits unsuccessfully" ()
    (define expected-exit-code 1)
    (define drv
      (set-fields (empty-derivation)
        ((derivation-builder) "/missing-builder-executable")))

    (define observations
      (deadline 5
        (let-values (((output captured-bytes) (open-bytevector-output-port)))
          (define status
            (execute-builder! drv "/store" "/tmp" 1
                              (lambda (bytes) (put-bytevector output bytes))))

          (list (positive? (bytevector-length (captured-bytes)))
                (status:exit-val status)))))

    (match-let (((diagnostic-received? exit-code) observations))
      (is diagnostic-received?)
      (is (equal? expected-exit-code exit-code))))

  (test "an error while handling builder output reaches the caller unchanged" ()
    (define drv (builder-derivation '(begin (display "builder output") (force-output))))
    (define exception-preserved?
      (deadline 5
        (define expected-exception (make-exception-with-message "log consumer failed"))
        (define actual-exception
          (capture-exception
           (lambda ()
             (execute-builder! drv "/store" "/tmp" 1
                               (lambda (_) (raise-exception expected-exception))))))

        (eq? expected-exception actual-exception)))

    (is exception-preserved?)))
