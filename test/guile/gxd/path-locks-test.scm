;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd path-locks-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd path-locks) #:select (call-with-destination-lock))
  #:use-module (gxd test-prelude)
  #:use-module ((guix build syscalls) #:select (fcntl-flock))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((ice-9 exceptions)
                #:select (exception-args exception-kind raise-exception))
  #:use-module ((ice-9 match) #:select (match)))

(define (lock-available? destination)
  "Return whether a separate process can immediately lock DESTINATION's lock file.
Propagate errors other than lock contention; bound the child lifetime."
  (call-with-process-deadline
   2
   (lambda ()
     (let ((port (open (string-append destination ".lock")
                       (logior O_RDWR O_CREAT O_CLOEXEC) #o600)))
       (dynamic-wind
         (lambda () #t)
         (lambda ()
           (let ((failure (capture-exception
                           (lambda () (fcntl-flock port 'write-lock #:wait? #f)))))
             (if failure
                 (match (cons (exception-kind failure) (exception-args failure))
                   (('flock-error errno)
                    (if (memv errno (list EACCES EAGAIN))
                        #f
                        (raise-exception failure)))
                   (_ (raise-exception failure)))
                 #t)))
         (lambda () (close-port port)))))))

(define-suite (path-locks-tests)
  (test "destination scope excludes another process and releases on return" ()
    (call-with-temporary-directory
     (lambda (directory)
       (define destination (string-append directory "/item"))
       (define probe (string-append directory "/probe"))
       (define available-inside?
         (call-with-destination-lock destination
           (lambda ()
             ;; Retain the inode so release is checked even after its name is removed.
             (link (string-append destination ".lock") (string-append probe ".lock"))
             (lock-available? probe))))

       (is (eq? #f available-inside?))
       (is (lock-available? probe)))))

  (test "destination scope releases on error and preserves the body's exception" ()
    (call-with-temporary-directory
     (lambda (directory)
       (define destination (string-append directory "/item"))
       (define probe (string-append directory "/probe"))
       (define available-inside? #t)
       (define expected-error (capture-exception (lambda () (error "body failure"))))
       (define actual-error
         (capture-exception
          (lambda ()
            (call-with-destination-lock destination
              (lambda ()
                (link (string-append destination ".lock") (string-append probe ".lock"))
                (set! available-inside? (lock-available? probe))
                (raise-exception expected-error))))))

       (is (eq? #f available-inside?))
       (is (eq? expected-error actual-error))
       (is (lock-available? probe))))))
