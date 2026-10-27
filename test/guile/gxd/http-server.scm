;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd http-server)
  #:use-module (gxd prelude)
  #:use-module ((gxd isolation) #:select (child-proc))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((web server) #:select (run-server))
  #:export (call-with-http-server))

(define (call-with-http-server handler proc)
  "Call PROC with the URL of a loopback HTTP server using HANDLER.
Stop and reap the server on return or exception; preserve PROC's values."
  (match-let (((pid => <= disconnect!)
               (child-proc SIGCHLD
                           (lambda (=> _)
                             (define listener (socket AF_INET SOCK_STREAM 0))
                             (bind listener AF_INET INADDR_LOOPBACK 0)
                             (listen listener 128)
                             (=> 'port (sockaddr:port (getsockname listener)))
                             (run-server handler 'http (list #:socket listener))))))
    (call-with-cleanup
     disconnect!
     (lambda ()
       (call-with-cleanup
        (lambda ()
          (kill pid SIGKILL)
          (waitpid pid))
        (lambda ()
          (proc (string-append "http://127.0.0.1:" (number->string (<= 'port))))))))))
