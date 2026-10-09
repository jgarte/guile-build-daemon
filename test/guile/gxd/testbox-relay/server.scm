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
  #:use-module ((gxd testbox-relay observation-protocol)
                #:select (make-observation-output write-accepted write-terminated)
                #:prefix observation:)
  #:export (run-relay))

(define (serve-client! client daemon-socket-path connection-id observation)
  "Relay CLIENT through DAEMON-SOCKET-PATH, then close both connected sockets
and report CONNECTION-ID's completion over OBSERVATION."
  (let ((daemon #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! daemon (connect-unix daemon-socket-path))
        (exchange! client daemon connection-id observation))
      (lambda ()
        (close-safely daemon)
        (close-safely client))))
  (observation:write-terminated observation connection-id))

(define (accept-clients! listener daemon-socket-path observation)
  "Report clients accepted on LISTENER to OBSERVATION with acceptance-order IDs,
and relay each independently through DAEMON-SOCKET-PATH."
  (let loop ((connection-id 1))
    (define client (car (restart-on-EINTR (accept listener))))
    (with-exception-handler
      (lambda (exception)
        (close-safely client)
        (raise-exception exception))
      (lambda ()
        (observation:write-accepted observation connection-id)
        (call-with-new-thread
         (lambda ()
           (serve-client! client daemon-socket-path connection-id
                          observation))))
      #:unwind? #t)
    (loop (+ connection-id 1))))

(define (run-relay relay-socket-path daemon-socket-path observation-socket-path)
  "Relay clients at RELAY-SOCKET-PATH independently through DAEMON-SOCKET-PATH.
Report accepted connections, forwarded bytes and completion over the socket at
OBSERVATION-SOCKET-PATH.
Run in a dedicated process; process exit releases outstanding workers."
  ;; Socket writes must raise EPIPE rather than terminate the relay.
  (sigaction SIGPIPE SIG_IGN)
  ;; Connecting observation announces that the relay is already listening.
  (let* ((listener (listen-unix relay-socket-path))
         (port (connect-unix observation-socket-path))
         (observation (observation:make-observation-output port)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (accept-clients! listener daemon-socket-path observation))
      (lambda ()
        (close-safely port)
        (close-safely listener)))))
