;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd guix-command-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd test-fixtures) #:select (paired-testbox-fixtures))
  #:use-module (gxd test-prelude))

(define-suite (guix-command-tests)
  (test "paired Guix deletion invalidates a registered text item" (ctx)
    'metadata `((test/fixtures . ,(paired-testbox-fixtures 'rootless 'nixd 'nixd)))
    (let ((step! (get ctx 'step!))
          (guix-command! (get ctx 'guix-command!)))

      (define path
        (step! '(add-text-to-store "name" "content")))
      (is (step! `(valid-path? ,path)))

      (is (= 0 (guix-command! "gc" "--delete" path)))
      (is (not (step! `(valid-path? ,path)))))))
