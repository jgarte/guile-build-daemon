;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox btrfs-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd test-prelude) #:select (capture-exception))
  #:use-module ((gxd testbox btrfs)
                #:select (delete-testbox-root! require-testbox-base)))

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
        (lambda () (setenv "TESTBOX_BTRFS" saved))))))
