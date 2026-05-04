;;; Raw full-duplex relay and connection lifecycle.

(define-module (guix-gd daemon relay)
  #:use-module (guix-gd daemon constants)
  #:use-module (guix-gd daemon context)
  #:use-module (guix-gd daemon logging)
  #:use-module (guix-gd daemon observer)
  #:use-module (ice-9 threads)      ; call-with-new-thread, join-thread
  #:use-module (ice-9 binary-ports) ; get-bytevector-some!, put-bytevector
  #:use-module (rnrs bytevectors)   ; make-bytevector
  #:use-module (rnrs io ports)      ; force-output
  #:export (split-socket
            close-safely
            forward
            relay-one
            ensure-listen-path-free
            serve-forever))

(define (split-socket socket)
  "Return dedicated read and write ports for SOCKET.

The relay duplicates the underlying file descriptor and re-opens it with
`fdopen` in explicit read-only and write-only modes.  This avoids subtle hangs
seen when two threads share one bidirectional port object."
  (values (fdopen (dup (port->fdes socket)) "rb")
          (fdopen (dup (port->fdes socket)) "wb")))

(define (close-safely port)
  "Close PORT and log failures instead of hiding them during cleanup."
  (when port
    (catch #t
      (lambda () (close-port port))
      (lambda args
        (log "close failed: ~s~%" args)))))

(define (forward label in out out-socket observer)
  "Copy bytes from IN to OUT until EOF, logging each chunk.

The relay uses `get-bytevector-some!` instead of `get-bytevector-n!`.  The
former returns as soon as *some* bytes are available, which is what a proxy
needs.  The latter tries to fill the requested range and caused stalls during
experiments.

On EOF the relay calls `shutdown` with mode `1` on OUT-SOCKET.  That is a
half-close: it tells the peer that no more bytes will be written in this
direction while still allowing the opposite direction to drain remaining data."
  (let ((buf (make-bytevector relay-buffer-size)))
    (catch #t
      (lambda ()
        (let loop ()
          (let ((n (get-bytevector-some! in buf 0 relay-buffer-size)))
            (cond
             ((eof-object? n)
              (log "~a EOF~%" label)
              (catch #t
                (lambda () (shutdown out-socket 1))
                (lambda args
                  (log "~a shutdown(write) failed: ~s~%" label args))))
             ((= n 0)
              (log "~a read 0 bytes~%" label)
              (catch #t
                (lambda () (shutdown out-socket 1))
                (lambda args
                  (log "~a shutdown(write) failed: ~s~%" label args))))
             (else
              (log "~a ~a bytes: ~a~%" label n (summarise-bytevector buf n))
              (put-bytevector out buf 0 n)
              (force-output out)
              (when observer
                (observer buf n))
              (loop))))))
      (lambda args
        (log "~a exception: ~s~%" label args)
        (catch #t
          (lambda () (shutdown out-socket 2))
          (lambda _ #f))))))

(define (relay-one client-socket upstream-path)
  "Relay one client connection to the daemon at UPSTREAM-PATH."
  (let ((ctx (make-connection-context))
        (client-state (make-client-decoder-state))
        (daemon-state (make-daemon-decoder-state))
        (upstream-socket #f)
        (client-in #f)
        (client-out #f)
        (upstream-in #f)
        (upstream-out #f))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (set! upstream-socket (socket AF_UNIX SOCK_STREAM 0))
        (connect upstream-socket AF_UNIX upstream-path)
        (log "connected upstream: ~a~%" upstream-path)

        (call-with-values
            (lambda () (split-socket client-socket))
          (lambda (in out)
            (set! client-in in)
            (set! client-out out)))

        (call-with-values
            (lambda () (split-socket upstream-socket))
          (lambda (in out)
            (set! upstream-in in)
            (set! upstream-out out)))

        ;; Each direction gets its own thread because client requests and daemon
        ;; frames are independent streams.  A single synchronous loop would block
        ;; on one side and starve the other.
        (let ((t1 (call-with-new-thread
                   (lambda ()
                     (forward "client -> daemon"
                              client-in
                              upstream-out
                              upstream-socket
                              (lambda (buf n)
                                (observe-client-bytevector!
                                 ctx client-state buf n))))))
              (t2 (call-with-new-thread
                   (lambda ()
                     (forward "daemon -> client"
                              upstream-in
                              client-out
                              client-socket
                              (lambda (buf n)
                                (observe-daemon-bytevector!
                                 ctx daemon-state buf n)))))))
          (join-thread t1)
          (join-thread t2)
          (log "relay finished~%")))
      (lambda ()
        (close-safely client-in)
        (close-safely client-out)
        (close-safely upstream-in)
        (close-safely upstream-out)
        (close-safely upstream-socket)
        (close-safely client-socket)))))

(define (ensure-listen-path-free path)
  "Ensure PATH is safe to bind.

The relay refuses to unlink an existing socket automatically because the path is
usually the real daemon socket.  Accidentally deleting a live daemon's pathname
would make the system harder to recover."
  (when (file-exists? path)
    (error "Listen socket path already exists; choose another path or stop the daemon using it"
           path)))

(define (serve-forever server upstream-path)
  "Accept clients from SERVER one at a time and relay them to UPSTREAM-PATH."
  (let loop ()
    (let* ((accepted (accept server))
           (client-socket (car accepted)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (log "accepted client~%")
          (relay-one client-socket upstream-path))
        (lambda ()
          (close-safely client-socket)))
      (loop))))
