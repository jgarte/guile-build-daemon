;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd worker-protocol)
  #:use-module ((guix serialization) #:select (long-long read-value))
  #:export (read-integer))

(define (read-integer port)
  "Read a worker-protocol integer from PORT, rejecting values above 32 bits."
  ;; Unlike Guix's integer reader, nix/libutil/serialise.cc readInt rejects
  ;; nonzero upper bytes.
  (let ((value (read-value long-long port)))
    (when (> value #xffffffff)
      (error "implementation cannot deal with > 32-bit integers"))
    value))
