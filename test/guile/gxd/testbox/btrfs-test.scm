;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox btrfs-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd test-prelude) #:select (capture-exception))
  #:use-module ((gxd testbox btrfs)
                #:select (delete-testbox-root!
                          require-testbox-base
                          snapshot-base!)))

(define-suite (testbox-btrfs-tests)
  (test "a missing base is refused" ()
    (let ((directory
           (mkdtemp (string-append (getenv "TESTBOX_BTRFS")
                                   "/missing-base-test-XXXXXX"))))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (is (capture-exception
               (lambda () (require-testbox-base directory)))))
        (lambda () (rmdir directory)))))

  (test "missing Btrfs configuration is rejected" ()
    (let ((saved (getenv "TESTBOX_BTRFS")))
      (dynamic-wind
        (lambda () (unsetenv "TESTBOX_BTRFS"))
        (lambda ()
          (is (capture-exception (lambda () (require-testbox-base)))))
        (lambda () (setenv "TESTBOX_BTRFS" saved)))))

  (test "a base snapshot is writable, isolated, and deletable" ()
    (let ((base (require-testbox-base))
          (pid1 (getpid))
          (root #f))
      (dynamic-wind
        (lambda () (set! root (snapshot-base! pid1)))
        (lambda ()
          (define item (string-append root "/gnu/store/btrfs-test-item"))

          (call-with-output-file item (lambda (port) (display "written" port)))

          (is (file-exists? item))
          (is (not (file-exists?
                    (string-append base "/gnu/store/btrfs-test-item"))))

          (delete-testbox-root! pid1)
          (is (not (file-exists? root))))
        (lambda ()
          (when (and root (file-exists? root))
            (delete-testbox-root! pid1))))))

  (test "the base is not snapshotted onto an existing root" ()
    (let ((pid1 (getpid))
          (root #f))
      (dynamic-wind
        (lambda () (set! root (snapshot-base! pid1)))
        (lambda ()
          (is (capture-exception (lambda () (snapshot-base! pid1))))
          (is (file-exists? root)))
        (lambda ()
          (when (and root (file-exists? root))
            (delete-testbox-root! pid1)))))))
