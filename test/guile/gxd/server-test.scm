;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd server-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix store) #:select (direct-store-path))
  #:use-module ((gxd test-fixtures) #:select (paired-testbox-fixtures))
  #:use-module (gxd test-prelude))

(define-suite (server-tests)
  'metadata `((test/fixtures . ,(paired-testbox-fixtures 'rootless 'nixd 'gxd)))

  (test "validity queries continue after an outside-store error on one connection" (ctx)
    (let* ((step! (get ctx 'step!))
           (present (direct-store-path
                     (canonicalize-path (require-program "guix-daemon"))))
           (absent "/gnu/store/00000000000000000000000000000000-gxd-absent"))

      (is (chain `(valid-path? ,present)
            (step! _ #:connection 'a)
            (eq? #t _)))

      (is (chain '(valid-path? "/outside")
            (step! _ #:connection 'a)
            (equal? '((error/type . store-protocol-error)
                      (error/message . "path `/outside' is not in the store")
                      (error/status . 1))
                    _)))

      (is (chain `(valid-path? ,absent)
            (step! _ #:connection 'a #:terminal? #t)
            (eq? #f _)))))

  (test "registered path is valid on nixd and gxd" (ctx)
    (let ((step! (get ctx 'step!))
          (path (direct-store-path
                 (canonicalize-path (require-program "guix-daemon")))))
      (is (eq? #t (step! `(valid-path? ,path))))))

  (test "unregistered path is invalid on nixd and gxd" (ctx)
    (let ((step! (get ctx 'step!)))
      (is (eq? #f (step! '(valid-path? "/gnu/store/00000000000000000000000000000000-gxd-absent"))))))

  (test "outside-store path has the same protocol error on nixd and gxd" (ctx)
    (let ((step! (get ctx 'step!)))
      (is (equal? '((error/type . store-protocol-error)
                    (error/message . "path `/outside' is not in the store")
                    (error/status . 1))
                  (step! '(valid-path? "/outside")))))))
