(use-modules (ice-9 threads)
             (rnrs bytevectors))

(define (log-data prefix bv)
  "Prints the data to stdout with a prefix."
  (let ((msg (utf8->string bv))) ; Assumes UTF-8
    (format #t "\n[~a]: ~a\n" prefix (string-trim-both msg))))

(define (proxy-pipe in-port out-port prefix)
  (catch 'system-error
    (lambda ()
      (let loop ()
        (let ((bv (get-bytevector-n in-port 4096)))
          ;; 4096 number specifies the maximum number of bytes to read in one go.
          ;; 4096 bytes is a standard "page size" that balances memory usage and performance.
          (unless (eof-object? bv)
            (log-data prefix bv)
            (put-bytevector out-port bv)
            (force-output out-port)
            (loop)))))
    (lambda _ (close-port in-port) (close-port out-port))))

(define (run-proxy listen-path backend-path)
  (let ((server (socket AF_UNIX SOCK_STREAM 0)))
    (when (file-exists? listen-path) (delete-file listen-path))
    (bind server AF_UNIX listen-path)
    (listen server 5)
    (format #t "Proxy active: ~a -> ~a\n" listen-path backend-path)
    (let accept-loop ()
      (let* ((client-connection (accept server))
             (client-port (car client-connection))
             (backend-port (socket AF_UNIX SOCK_STREAM 0)))
        (catch 'system-error
          (lambda ()
            (connect backend-port AF_UNIX backend-path)
            ;; Bridge with labels for logging
            (make-thread proxy-pipe client-port backend-port "CLIENT->DAEMON")
            (make-thread proxy-pipe backend-port client-port "DAEMON->CLIENT"))
          (lambda _
            (display "Error: Could not reach backend.\n")
            (close-port client-port))))
      (accept-loop))))

;; (run-proxy "/tmp/guix-proxy.socket" "/var/guix/daemon-socket/socket")

(define (main args)
  (if (= (length args) 3)
      (run-proxy (list-ref args 1) (list-ref args 2))
      (display "Usage: guix-proxy <listen-path> <backend-path>\n")))

(main (command-line))
