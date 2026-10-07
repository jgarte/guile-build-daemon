;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay connection)
  #:use-module ((rnrs bytevectors) #:select (make-bytevector))
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:export (forward!))

;; Shut down sending without disabling reception on the same socket.
(define SHUT_WR 1)

(define (forward! source destination)
  "Forward SOURCE to DESTINATION until EOF, then close DESTINATION's write half."
  (let ((buffer (make-bytevector 65536)))
    (let loop ()
      ;; Read into BUFFER, retrying signal interruptions; zero bytes means EOF.
      (define count (restart-on-EINTR (recv! source buffer)))
      (if (zero? count)
          ;; Propagate EOF to the peer while leaving its response path open.
          (restart-on-EINTR (shutdown destination SHUT_WR))
          (begin
            (put-bytevector destination buffer 0 count)
            (loop))))))
