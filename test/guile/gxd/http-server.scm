;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd http-server)
  #:use-module (gxd prelude)
  #:use-module ((gxd isolation) #:select (child-proc))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((ice-9 threads) #:select (call-with-new-thread make-mutex with-mutex))
  #:use-module ((web server) #:select (run-server))
  #:export (call-with-http-server))

(define (call-with-http-server handler proc)
  "Call PROC with a loopback HTTP server's URL and a request-count procedure.
Use HANDLER for responses; count requests received before each count query.
Stop and reap the server on return or exception; preserve PROC's values."
  (match-let (((pid => <= disconnect!)
               (child-proc SIGCHLD
                           (lambda (=> <=)
                             (define count 0)
                             (define mutex (make-mutex))
                             (define (counted-handler request body)
                               (with-mutex mutex (set! count (+ count 1)))
                               (handler request body))

                             (define listener (socket AF_INET SOCK_STREAM 0))
                             (bind listener AF_INET INADDR_LOOPBACK 0)
                             (listen listener 128)
                             (call-with-new-thread
                              (lambda ()
                                (run-server counted-handler 'http (list #:socket listener))))
                             (=> 'port (sockaddr:port (getsockname listener)))
                             (while #t
                               (<= 'request-count)
                               (=> 'request-count (with-mutex mutex count)))))))
    (call-with-cleanup
     disconnect!
     (lambda ()
       (call-with-cleanup
        (lambda ()
          (kill pid SIGKILL)
          (waitpid pid))
        (lambda ()
          (define (request-count)
            (=> 'request-count)
            (<= 'request-count))

          (proc (string-append "http://127.0.0.1:" (number->string (<= 'port)))
                request-count)))))))
