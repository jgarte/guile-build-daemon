;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay connection)
  #:use-module ((ice-9 exceptions) #:select (raise-exception with-exception-handler))
  #:use-module ((ice-9 threads) #:select (call-with-new-thread join-thread))
  #:use-module ((rnrs bytevectors) #:select (make-bytevector))
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:export (forward! exchange!))

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

(define (exchange! client daemon)
  "Forward CLIENT and DAEMON in both directions until both reach EOF.
Raise on forwarding failure.  Both directions have stopped before return or raise.
The caller owns both sockets and must ignore SIGPIPE."

  (define (stop!)
    ;; Wake a blocked receive before joining after a forwarding failure.
    (false-if-exception (shutdown client 2))
    (false-if-exception (shutdown daemon 2)))

  (define worker
    (call-with-new-thread
     (lambda ()
       (with-exception-handler
           (lambda (exception) (stop!) exception)
         (lambda () (forward! daemon client) #f)
         #:unwind? #t))))

  (define worker-failure #f)
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (forward! client daemon)
      (set! worker-failure (join-thread worker)))
    (lambda ()
      (stop!)
      (join-thread worker)))
  (when worker-failure (raise-exception worker-failure)))
