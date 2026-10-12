;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd worker-protocol-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((rnrs io ports) #:select (open-bytevector-input-port get-u8))
  #:use-module ((gxd worker-protocol) #:select (read-integer read-string)
                #:prefix protocol:))

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
          (open-bytevector-input-port #vu8(1 0 0 0 0 0 0 0 97 0 0 0 0 0 0)))))))
