;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox disk-test)
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((gxd test-prelude) #:select (spit))
  #:use-module ((gxd testbox disk)
                #:select (delete-testbox-root!
                          require-testbox-base
                          snapshot-base!)))

(define (call-with-testbox-root proc)
  "Call PROC with the PID and path of a fresh testbox root, then delete it."
  (let* ((pid1 (getpid))
         (testbox-root (snapshot-base! pid1)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc pid1 testbox-root))
      (lambda ()
        (when (file-exists? testbox-root)
          (delete-testbox-root! pid1))))))

(define-suite (testbox-disk-tests)
  (test "the installed base is available" ()
    (is (string? (require-testbox-base))))

  (test "a non-Btrfs filesystem is rejected" ()
    (is (throws-exception? (require-testbox-base "/proc"))))

  (test "a base snapshot is writable, isolated, and deletable" ()
    (define base (require-testbox-base))
    (let-values (((testbox-root writable? isolated?)
                  (call-with-testbox-root
                   (lambda (_ testbox-root)
                     (define item
                       (string-append testbox-root
                                      "/gnu/store/disk-test-item"))
                     (spit item "written")
                     (values testbox-root
                             (file-exists? item)
                             (not (file-exists?
                                   (string-append
                                    base "/gnu/store/disk-test-item"))))))))
      (is writable?)
      (is isolated? "the item was not written to the base")
      (is (not (file-exists? testbox-root)))))

  (test "the base is not snapshotted onto an existing root" ()
    (let-values (((testbox-root rejected? preserved?)
                  (call-with-testbox-root
                   (lambda (pid1 testbox-root)
                     (values testbox-root
                             (throws-exception? (snapshot-base! pid1))
                             (file-exists? testbox-root))))))
      (is rejected?)
      (is preserved?)
      (is (not (file-exists? testbox-root)))))

  (test "a snapshot is deleted when its user raises" ()
    (is (throws-exception?
         (call-with-testbox-root (lambda _ (error "expected failure")))))
    (is (call-with-testbox-root (lambda _ #t)))))
