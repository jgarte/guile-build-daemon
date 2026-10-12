;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay-test)
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix store) #:select (direct-store-path))
  #:use-module ((gxd direct-steps) #:select (direct-steps-fixture))
  #:use-module ((gxd test-fixtures) #:select (paired-testbox-fixtures))
  #:use-module (gxd test-prelude)
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture))
  #:use-module ((gxd testbox-relay)
                #:select (client-trust-fixture paired-relay-observers-fixture)))

(define paired-relay-fixtures
  (list (client-trust-fixture #f)
        (paired-daemon-testboxes-fixture 'rootless 'nixd 'nixd)
        paired-relay-observers-fixture
        direct-steps-fixture))

(define-suite (testbox-relay-tests)
  (test "two named queries change the stable single-query capture" (ctx)
    'metadata `((test/fixtures . ,paired-relay-fixtures))
    (let* ((step! (get ctx 'step!))
           (observe-bytes! (get ctx 'observe-bytes!))
           (present (direct-store-path
                     (canonicalize-path (require-program "guix-daemon"))))
           (op `(valid-path? ,present)))

      (is (eq? #t (step! op)))

      (define first (observe-bytes!))
      (is (bytevector=? (car first) (cadr first)))

      (is (eq? #t (step! op)))

      (define second (observe-bytes!))
      (is (equal? first second))

      (is (eq? #t (step! op #:connection 'a)))
      (is (eq? #t (step! op #:connection 'a #:terminal? #t)))

      (define session (observe-bytes!))
      (is (bytevector=? (car session) (cadr session)))
      (is (not (bytevector=? (car first) (car session))))))

  (test "checked valid-path steps agree for present and absent store items" (ctx)
    'metadata `((test/fixtures . ,(paired-testbox-fixtures 'rootless 'nixd 'nixd)))
    (let* ((step! (get ctx 'step!))
           (present (direct-store-path
                     (canonicalize-path (require-program "guix-daemon"))))
           (absent "/gnu/store/00000000000000000000000000000000-gxd-absent"))
      (is (step! `(valid-path? ,present)))
      (is (not (step! `(valid-path? ,absent))))))

  (test "paired captures agree and change with the queried path" (ctx)
    'metadata `((test/fixtures . ,paired-relay-fixtures))
    (let* ((step! (get ctx 'step!))
           (observe-bytes! (get ctx 'observe-bytes!))
           (path (direct-store-path
                  (canonicalize-path (require-program "guix-daemon"))))
           (other-path (direct-store-path
                        (canonicalize-path (require-program "guile")))))
      (when (equal? path other-path)
        (error "test paths were meant to be distinct" path other-path))

      (is (step! `(valid-path? ,path)))

      (define first (observe-bytes!))
      (is (bytevector=? (car first) (cadr first)))

      (is (step! `(valid-path? ,other-path)))

      (define second (observe-bytes!))
      (is (bytevector=? (car second) (cadr second)))
      (is (not (bytevector=? (car first) (car second)))))))
