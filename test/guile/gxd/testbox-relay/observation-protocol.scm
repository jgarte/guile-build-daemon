;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay observation-protocol)
  #:use-module ((guix serialization) #:select (write-long-long))
  #:export (frame-accepted write-accepted))

;; Scalars are unsigned little-endian 64-bit integers.
;; ACCEPTED CONNECTION-ID
(define frame-accepted 1)

(define (put-scalars port values)
  (for-each (lambda (value) (write-long-long value port)) values))

(define (write-accepted port id)
  "Write an accepted-connection frame for positive ID to PORT."
  (put-scalars port (list frame-accepted id))
  (force-output port))
