;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay observation-protocol)
  #:use-module ((rnrs bytevectors) #:select (bytevector-length))
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:use-module ((guix serialization) #:select (write-long-long))
  #:export (frame-accepted frame-data frame-terminated
                           write-accepted write-data write-terminated))

;; Scalars are unsigned little-endian 64-bit integers; byte payloads are unpadded.
;; ACCEPTED   CONNECTION-ID
;; DATA       CONNECTION-ID FROM LENGTH <BYTES>
;; TERMINATED CONNECTION-ID STATUS
;; STATUS: 1 = complete.
;; FROM: 1 = client, 2 = daemon.
(define frame-accepted 1)
(define frame-data 2)
(define frame-terminated 3)

(define (put-scalars port values)
  (for-each (lambda (value) (write-long-long value port)) values))

(define (write-accepted port id)
  "Write an accepted-connection frame for positive ID to PORT."
  (put-scalars port (list frame-accepted id))
  (force-output port))

(define (from->integer from)
  (case from
    ((client) 1)
    ((daemon) 2)
    (else (error "invalid relay observation source" from))))

(define (write-data port connection-id from bytes)
  "Write to PORT a DATA frame for CONNECTION-ID FROM ('client or 'daemon),
carrying BYTES."
  (put-scalars port
               (list frame-data connection-id (from->integer from)
                     (bytevector-length bytes)))
  (put-bytevector port bytes)
  (force-output port))

(define (write-terminated port connection-id)
  "Write to PORT a completed-connection frame for CONNECTION-ID."
  (put-scalars port (list frame-terminated connection-id 1))
  (force-output port))
