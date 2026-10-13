;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd worker-protocol)
  #:use-module ((guix serialization) #:select (integer long-long utf8-string
                                                       read-value write-value))
  #:use-module ((rnrs bytevectors) #:select (bytevector-length
                                             bytevector-u8-ref
                                             bytevector-copy!
                                             make-bytevector utf8->string))
  #:use-module ((rnrs io ports) #:select (get-bytevector-n))
  #:export (read-integer read-boolean read-string read-string-pairs read-options
                         write-completion write-error write-log))

(define STDERR_LAST #x616c7473)
(define STDERR_ERROR #x63787470)
(define STDERR_NEXT #x6f6c6d67)

(define (write-log message port)
  "Write MESSAGE as a worker-protocol log frame to PORT."
  (write-value integer STDERR_NEXT port)
  (write-value utf8-string message port))

(define (write-completion port)
  "Write the work-completion marker to PORT."
  (write-value integer STDERR_LAST port))

(define (write-error message status port)
  "Write a worker-protocol error with MESSAGE and STATUS to PORT."
  (write-value integer STDERR_ERROR port)
  (write-value utf8-string message port)
  (write-value integer status port))

(define (read-integer port)
  "Read a worker-protocol integer from PORT, rejecting values above 32 bits."
  ;; Unlike Guix's integer reader, nix/libutil/serialise.cc readInt rejects
  ;; nonzero upper bytes.
  (let ((value (read-value long-long port)))
    (when (> value #xffffffff)
      (error "implementation cannot deal with > 32-bit integers"))
    value))

(define (read-boolean port)
  "Read a worker-protocol Boolean from PORT; zero is false, nonzero is true."
  (not (zero? (read-integer port))))

(define (read-options port)
  "Read a pinned-protocol set-options payload from PORT as keyed data.
Boolean fields use zero/nonzero truthiness; SETTINGS preserves wire pair order.
The operation number is already consumed."
  ;; Sequence port reads explicitly; quasiquote does not guarantee their order.
  (let* ((keep-failed? (read-boolean port))
         (keep-going? (read-boolean port))
         (fallback? (read-boolean port))
         (verbosity (read-integer port))
         (offload? (read-boolean port))
         (build-verbosity (read-integer port))
         (log-type (read-integer port))
         (print-build-trace? (read-boolean port))
         (use-substitutes? (read-boolean port))
         (settings (read-string-pairs port)))
    `((keep-failed? . ,keep-failed?)
      (keep-going? . ,keep-going?)
      (fallback? . ,fallback?)
      (verbosity . ,verbosity)
      (offload? . ,offload?)
      (build-verbosity . ,build-verbosity)
      (log-type . ,log-type)
      (print-build-trace? . ,print-build-trace?)
      (use-substitutes? . ,use-substitutes?)
      (settings . ,settings))))

(define (read-string-pairs port)
  "Read ordered UTF-8 string pairs from PORT, preserving duplicate keys."
  (let loop ((remaining (read-integer port)) (pairs '()))
    (if (zero? remaining)
        (reverse pairs)
        (let* ((name (read-string port))
               (value (read-string port)))
          (loop (1- remaining) (cons (cons name value) pairs))))))

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
