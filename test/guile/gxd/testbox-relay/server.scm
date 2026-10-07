;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay server)
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:use-module ((gxd testbox-relay socket) #:select (close-safely listen-unix))
  #:export (run-relay))

(define (run-relay relay-socket-path)
  "Listen at RELAY-SOCKET-PATH and accept one client, then return."
  (let ((listener (listen-unix relay-socket-path)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (close-safely (car (restart-on-EINTR (accept listener)))))
      (lambda () (close-safely listener)))))
