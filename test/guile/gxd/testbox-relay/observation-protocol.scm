;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay observation-protocol)
  #:use-module ((ice-9 threads) #:select (make-mutex with-mutex))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:use-module ((rnrs bytevectors) #:select (bytevector-length))
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:use-module ((guix serialization) #:select (write-long-long))
  #:export (make-observation-output frame-accepted frame-data frame-terminated
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

(define-record-type <observation-output>
  (observation-output port mutex)
  observation-output?
  (port observation-output-port)
  (mutex observation-output-mutex))

(define (make-observation-output port)
  "Return a serialized frame output over PORT.  The caller retains ownership of PORT."
  (observation-output port (make-mutex)))

(define (put-scalars port values)
  (for-each (lambda (value) (write-long-long value port)) values))

(define (write-accepted output id)
  "Write to OUTPUT an accepted-connection frame for ID."
  (with-mutex (observation-output-mutex output)
              (let ((port (observation-output-port output)))
                (put-scalars port (list frame-accepted id))
                (force-output port))))

(define (from->integer from)
  (case from
    ((client) 1)
    ((daemon) 2)
    (else (error "invalid relay observation source" from))))

(define (write-data output connection-id from bytes)
  "Write to OUTPUT a DATA frame for CONNECTION-ID FROM ('client or 'daemon),
carrying BYTES."
  (with-mutex (observation-output-mutex output)
              (let ((port (observation-output-port output)))
                (put-scalars port
                             (list frame-data connection-id (from->integer from)
                                   (bytevector-length bytes)))
                (put-bytevector port bytes)
                (force-output port))))

(define (write-terminated output connection-id)
  "Write to OUTPUT a completed-connection frame for CONNECTION-ID."
  (with-mutex (observation-output-mutex output)
              (let ((port (observation-output-port output)))
                (put-scalars port (list frame-terminated connection-id 1))
                (force-output port))))
