;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox files-info-diff-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd testbox files-info-diff) #:select (diff-files-info)))

(define-suite (files-info-diff-tests)
  (test "sorted inventories retain unique entries and describe changed fields" ()
    (let ((left '(("a" (type . directory))
                  ("c" (mode . 420))
                  ("e" (type . regular))
                  ("g" (type . symlink) (target . "old"))))
          (right '(("b" (type . directory))
                   ("c" (mode . 292))
                   ("e" (type . regular))
                   ("g" (type . regular))
                   ("z" (type . regular)))))
      (is (equal? '((only-left ("a" (type . directory)))
                    (only-right ("b" (type . directory)) ("z" (type . regular)))
                    (changed
                     ("c" (mode) ((mode . 420)) ((mode . 292)))
                     ("g" (type target)
                      ((type . symlink) (target . "old")) ((type . regular)))))
                  (diff-files-info left right)))

      (is (equal? '((only-left ("b" (type . directory)) ("z" (type . regular)))
                    (only-right ("a" (type . directory)))
                    (changed
                     ("c" (mode) ((mode . 292)) ((mode . 420)))
                     ("g" (type target)
                      ((type . regular)) ((type . symlink) (target . "old")))))
                  (diff-files-info right left)))))

  (test "empty and equal inventories have no differences" ()
    (is (equal? '((only-left) (only-right) (changed)) (diff-files-info '() '())))
    (is (equal? '((only-left) (only-right) (changed))
                (diff-files-info '(("a" (type . regular)))
                                 '(("a" (type . regular))))))))
