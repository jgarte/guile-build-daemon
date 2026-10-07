;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay server)
  #:use-module ((ice-9 exceptions) #:select (raise-exception with-exception-handler))
  #:use-module ((ice-9 threads) #:select (call-with-new-thread))
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:use-module ((gxd testbox-relay socket)
                #:select (close-safely connect-unix listen-unix))
  #:use-module ((gxd testbox-relay connection) #:select (exchange!))
  #:export (run-relay))

(define (serve-client! client daemon-socket-path)
  "Relay CLIENT through DAEMON-SOCKET-PATH, then close both connected sockets."
  (let ((daemon #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! daemon (connect-unix daemon-socket-path))
        (exchange! client daemon))
      (lambda ()
        (close-safely daemon)
        (close-safely client)))))

(define (accept-clients! listener daemon-socket-path)
  "Accept clients on LISTENER and relay each independently through DAEMON-SOCKET-PATH."
  (let loop ()
    (define client (car (restart-on-EINTR (accept listener))))
    (with-exception-handler
        (lambda (exception)
          (close-safely client)
          (raise-exception exception))
      (lambda ()
        (call-with-new-thread
         (lambda () (serve-client! client daemon-socket-path))))
      #:unwind? #t)
    (loop)))

(define (run-relay relay-socket-path daemon-socket-path)
  "Relay clients at RELAY-SOCKET-PATH independently through DAEMON-SOCKET-PATH.
Run in a dedicated process; process exit releases outstanding workers."
  ;; Socket writes must raise EPIPE rather than terminate the relay.
  (sigaction SIGPIPE SIG_IGN)
  (let ((listener (listen-unix relay-socket-path)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (accept-clients! listener daemon-socket-path))
      (lambda () (close-safely listener)))))
