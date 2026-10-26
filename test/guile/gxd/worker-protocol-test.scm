;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd worker-protocol-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((guix serialization) #:select (integer utf8-string write-value))
  #:use-module ((rnrs io ports)
                #:select (open-bytevector-input-port open-bytevector-output-port
                                                     get-u8 put-u8))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((gxd worker-protocol)
                #:select (read-integer read-string read-header-of-add-to-store-op)
                #:prefix protocol:))

(define (make-header-for-add-to-store-op name fixed recursive hash-algo nar-byte)
  "Return a serialized add-to-store header followed by a sentinel NAR byte."
  (let-values (((port extract) (open-bytevector-output-port)))
    (write-value utf8-string name port)
    (write-value integer fixed port)
    (write-value integer recursive port)
    (write-value utf8-string hash-algo port)
    ;; sentinel NAR byte
    (put-u8 port nar-byte)
    (extract)))

(define-suite (worker-protocol-tests)
  (test "wire integer accepts the 32-bit maximum" ()
    (is (= #xffffffff
           (protocol:read-integer
            (open-bytevector-input-port #vu8(255 255 255 255 0 0 0 0))))))

  (test "wire integer rejects nonzero upper bits" ()
    (is (throws-exception?
         (protocol:read-integer
          (open-bytevector-input-port #vu8(0 0 0 0 1 0 0 0))))))

  (test "empty wire string leaves the following byte intact" ()
    (let ((port (open-bytevector-input-port #vu8(0 0 0 0 0 0 0 0 42))))
      (is (equal? "" (protocol:read-string port)))
      (is (= 42 (get-u8 port)))))

  (test "wire string consumes its zero padding but not the following byte" ()
    (let ((port (open-bytevector-input-port
                 #vu8(1 0 0 0 0 0 0 0 97 0 0 0 0 0 0 0 42))))
      (is (equal? "a" (protocol:read-string port)))
      (is (= 42 (get-u8 port)))))

  (test "wire string rejects nonzero padding" ()
    (is (throws-exception?
         (protocol:read-string
          (open-bytevector-input-port #vu8(1 0 0 0 0 0 0 0 97 0 0 0 0 0 0 1))))))

  (test "wire string rejects truncated data" ()
    (is (throws-exception?
         (protocol:read-string
          (open-bytevector-input-port #vu8(2 0 0 0 0 0 0 0 97))))))

  (test "wire string rejects truncated padding" ()
    (is (throws-exception?
         (protocol:read-string
          (open-bytevector-input-port #vu8(1 0 0 0 0 0 0 0 97 0 0 0 0 0 0))))))

  (test "add-to-store header leaves its NAR unread" ()
    (let* ((port (open-bytevector-input-port
                  (make-header-for-add-to-store-op "item" 1 0 "sha512" 42)))
           (request (protocol:read-header-of-add-to-store-op port)))
      (is (equal? "item" (assoc-ref request 'name)))
      (is (eq? #f (assoc-ref request 'recursive?)))
      (is (equal? "sha512" (assoc-ref request 'hash-algo)))
      (is (= 42 (get-u8 port)))))

  (test "obsolete add-to-store fixed field selects recursive SHA-256 mode" ()
    (let* ((port (open-bytevector-input-port
                  (make-header-for-add-to-store-op "item" 2 0 "sha512" 42)))
           (request (protocol:read-header-of-add-to-store-op port)))
      (is (eq? #t (assoc-ref request 'recursive?)))
      (is (equal? "sha256" (assoc-ref request 'hash-algo))))))
