;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay server)
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:use-module ((gxd testbox-relay socket)
                #:select (close-safely connect-unix listen-unix))
  #:use-module ((gxd testbox-relay connection) #:select (exchange!))
  #:export (run-relay))

(define (run-relay relay-socket-path daemon-socket-path)
  "Relay one client at RELAY-SOCKET-PATH through DAEMON-SOCKET-PATH until EOF.
Run in a dedicated process."
  ;; Socket writes must raise EPIPE rather than terminate the relay.
  (sigaction SIGPIPE SIG_IGN)
  (let ((listener (listen-unix relay-socket-path))
        (client #f)
        (daemon #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! client (car (restart-on-EINTR (accept listener))))
        (set! daemon (connect-unix daemon-socket-path))
        (exchange! client daemon))
      (lambda ()
        (close-safely daemon)
        (close-safely client)
        (close-safely listener)))))
