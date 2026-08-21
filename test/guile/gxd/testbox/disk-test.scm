;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox disk-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((gxd testbox disk) #:select (require-testbox-base)))

(define-suite (testbox-disk-tests)
  (test "the installed base is available" ()
    (is (string? (require-testbox-base))))

  (test "a non-Btrfs filesystem is rejected" ()
    (is (throws-exception? (require-testbox-base "/proc")))))
