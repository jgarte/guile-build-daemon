;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd server)
  #:use-module ((ice-9 exceptions) #:select (raise-exception
                                             with-exception-handler))
  #:use-module ((ice-9 match) #:select (match))
  #:export (run-server))

(define (run-server socket-path)
  "Listen at SOCKET-PATH and accept one connection, then return."
  (define listener (socket AF_UNIX SOCK_STREAM 0))

  (with-exception-handler
    (lambda (exception)
      (close-port listener)
      (raise-exception exception))
    (lambda ()
      ;; Like nixd's open_unix_socket, permit clients with other UIDs to connect.
      (let ((previous-mask (umask #o111)))
        (dynamic-wind
          (lambda () #t)
          (lambda () (bind listener AF_UNIX socket-path))
          (lambda () (umask previous-mask)))))
    #:unwind? #t)

  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (listen listener 1)
      (match (accept listener)
        ((connection . _) (close-port connection))))
    (lambda ()
      (close-port listener)
      (delete-file socket-path))))
