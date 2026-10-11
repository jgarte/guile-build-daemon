;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd socket)
  #:use-module ((system foreign) #:select (int pointer->procedure
                                               bytevector->pointer))
  #:use-module ((rnrs bytevectors) #:select (make-bytevector
                                             bytevector-u32-native-ref
                                             bytevector-u32-native-set!))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (peer-uid))

(define SO_PEERCRED 17)

(define get-peer-credentials
  (pointer->procedure int (dynamic-func "getsockopt" (dynamic-link))
                      (list int int int '* '*) #:return-errno? #t))

(define (peer-uid socket)
  "Return the UID of SOCKET's Unix-domain peer.  Raise if lookup fails."
  ;; Linux struct ucred holds a signed 32-bit PID and unsigned 32-bit UID/GID;
  ;; socklen_t is also unsigned 32-bit.
  (let ((credentials (make-bytevector 12 0))
        (length (make-bytevector 4 0)))
    (bytevector-u32-native-set! length 0 12)
    (let-values (((result errno)
                  (get-peer-credentials (fileno socket) SOL_SOCKET SO_PEERCRED
                                        (bytevector->pointer credentials)
                                        (bytevector->pointer length))))
      (unless (zero? result)
        (error "cannot read Unix peer credentials" (strerror errno)))
      (unless (= 12 (bytevector-u32-native-ref length 0))
        (error "unexpected Unix peer credentials size"))
      (bytevector-u32-native-ref credentials 4))))
