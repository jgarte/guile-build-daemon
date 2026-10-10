;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd worker-protocol)
  #:use-module ((guix serialization) #:select (long-long read-value))
  #:use-module ((rnrs bytevectors) #:select (bytevector-length
                                             bytevector-u8-ref
                                             bytevector-copy!
                                             make-bytevector utf8->string))
  #:use-module ((rnrs io ports) #:select (get-bytevector-n))
  #:export (read-integer read-string))

(define (read-integer port)
  "Read a worker-protocol integer from PORT, rejecting values above 32 bits."
  ;; Unlike Guix's integer reader, nix/libutil/serialise.cc readInt rejects
  ;; nonzero upper bytes.
  (let ((value (read-value long-long port)))
    (when (> value #xffffffff)
      (error "implementation cannot deal with > 32-bit integers"))
    value))

(define (read-string port)
  "Read a UTF-8 worker-protocol string from PORT, requiring zero padding."
  (let* ((length (read-integer port))
         (padding (modulo (- length) 8))
         (bytes (get-bytevector-n port (+ length padding))))

    (when (or (eof-object? bytes)
              (< (bytevector-length bytes) (+ length padding)))
      (error "unexpected end-of-file"))

    ;; nix/libutil/serialise.cc readPadding rejects nonzero padding.
    (let loop ((index length))
      (when (< index (+ length padding))
        (unless (zero? (bytevector-u8-ref bytes index))
          (error "non-zero padding"))
        (loop (+ index 1))))

    (let ((value (make-bytevector length)))
      (bytevector-copy! bytes 0 value 0 length)
      (utf8->string value))))
