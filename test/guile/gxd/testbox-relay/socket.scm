;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay socket)
  #:use-module ((ice-9 exceptions) #:select (raise-exception with-exception-handler))
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:export (close-safely connect-unix listen-unix))

(define (close-safely port)
  "Close PORT if present, ignoring any close error."
  (when port (false-if-exception (close-port port))))

(define (connect-unix path)
  "Return a connected Unix-domain socket for PATH, or raise on failure."
  (let ((port (socket AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)))
    (with-exception-handler
        (lambda (exception)
          (close-safely port)
          (raise-exception exception))
      (lambda ()
        (restart-on-EINTR (connect port AF_UNIX path))
        port)
      #:unwind? #t)))

(define (listen-unix path)
  "Return a listening Unix-domain socket at PATH, or raise on failure."
  (let ((listener (socket AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)))
    (with-exception-handler
        (lambda (exception)
          (close-safely listener)
          (raise-exception exception))
      (lambda ()
        (restart-on-EINTR (bind listener AF_UNIX path))
        ;; Allow the host harness to connect even when the socket is created
        ;; by a different UID inside the testbox.
        (chmod path #o666)
        (listen listener 16)
        listener)
      #:unwind? #t)))
