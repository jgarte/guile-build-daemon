;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build process-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd build process)
                #:select (call-with-builder-process builder-pid builder-output wait-builder!))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((ice-9 exceptions)
                #:select (exception-kind exception-args raise-exception
                                         make-exception-with-message))
  #:use-module ((ice-9 textual-ports) #:select (get-string-all))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((ice-9 rdelim) #:select (read-line)))

(define (reaped? pid)
  "Return whether PID has no waitable child status, as reported by ECHILD."
  (let ((exception (capture-exception (lambda () (waitpid pid WNOHANG)))))
    (and exception
         (eq? 'system-error (exception-kind exception))
         (= ECHILD (system-error-errno
                    (cons (exception-kind exception) (exception-args exception)))))))

(define-suite (builder-process-tests)
  (test "capture large stdout/stderr streams and reap a failing builder" ()
    (define guile (require-program "guile"))
    (define expected-exit-code 7)
    (define builder-expression
      `(begin
         (display (make-string 131072 #\x))
         (force-output)
         (display (make-string 131072 #\y) (current-error-port))
         (force-output (current-error-port))
         (exit ,expected-exit-code)))

    (define expected-output (string-append "\n" (make-string 131072 #\x) (make-string 131072 #\y)))
    (define observations
      (deadline 5
        (define output #f)
        (define result
          (call-with-builder-process
           guile (list "--no-auto-compile" "-c" (object->string builder-expression))
           '() "/tmp"
           (lambda (process)
             (set! output (builder-output process))
             ;; Return a small comparison result through the deadline helper.
             (define captured-output (get-string-all output))
             (define status (wait-builder! process))
             (list (equal? expected-output captured-output)
                   (status:exit-val status)
                   (reaped? (builder-pid process))))))

        (append result (list (port-closed? output)))))

    (match-let (((complete-output? exit-code child-reaped? output-closed?) observations))
      (is complete-output?)
      (is (equal? expected-exit-code exit-code))
      (is child-reaped?)
      (is output-closed?)))

  (test "raising in the callback terminates and reaps its running builder" ()
    (define guile (require-program "guile"))
    (define expected-exception (make-exception-with-message "leave builder scope"))
    (define observations
      (deadline 5
        (define pid #f)
        (define output #f)
        (define running? #f)
        (define failure
          (capture-exception
           (lambda ()
             (call-with-builder-process
              guile (list "--no-auto-compile" "-c"
                          (object->string
                           '(begin
                              (display "ready\n")
                              (force-output)
                              (sleep 60))))
              '() "/tmp"
              (lambda (process)
                (set! pid (builder-pid process))
                (set! output (builder-output process))
                (read-line output)
                (set! running? (and (equal? "ready" (read-line output))
                                    (zero? (car (waitpid pid WNOHANG)))))
                (raise-exception expected-exception))))))

        (list running? (eq? expected-exception failure)
              (reaped? pid) (port-closed? output))))

    (match-let (((running-before-error? exception-preserved? child-reaped? output-closed?) observations))
      (is running-before-error?)
      (is exception-preserved?)
      (is child-reaped?)
      (is output-closed?))))
