;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay server)
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:use-module ((gxd testbox-relay socket)
                #:select (close-safely connect-unix listen-unix))
  #:export (run-relay))

(define (run-relay relay-socket-path daemon-socket-path)
  "Accept one client at RELAY-SOCKET-PATH and connect to DAEMON-SOCKET-PATH,
then return."
  (let ((listener (listen-unix relay-socket-path))
        (client #f)
        (daemon #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! client (car (restart-on-EINTR (accept listener))))
        (set! daemon (connect-unix daemon-socket-path)))
      (lambda ()
        (close-safely daemon)
        (close-safely client)
        (close-safely listener)))))
