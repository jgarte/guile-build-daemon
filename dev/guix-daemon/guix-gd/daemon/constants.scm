;;; Shared constants for the Guix daemon relay.

(define-module (guix-gd daemon constants)
  #:export (default-listen-socket-path
            default-upstream-socket-path
            relay-buffer-size
            preview-limit
            string-preview-limit
            WORKER_MAGIC_1
            WORKER_MAGIC_2
            PROTOCOL_VERSION
            STDERR_NEXT
            STDERR_READ
            STDERR_WRITE
            STDERR_LAST
            STDERR_ERROR))

;; By default the relay listens on the normal Guix daemon socket.  This matches
;; the intended deployment: the relay becomes the daemon visible to clients,
;; while the real daemon is moved to a non-default fallback socket.
(define default-listen-socket-path "/var/guix/daemon-socket/socket")
(define default-upstream-socket-path "/tmp/guix-gd-fallback.sock")

;; Relay/logging limits.
(define relay-buffer-size 4096)
(define preview-limit 32)
(define string-preview-limit 120)

;; `worker-protocol.hh`
(define WORKER_MAGIC_1 #x6e697863)
(define WORKER_MAGIC_2 #x6478696f)
(define PROTOCOL_VERSION #x0164)

;; `worker-protocol.hh`: daemon control frames sent before normal operation
;; reply payloads.
(define STDERR_NEXT  #x6f6c6d67)
(define STDERR_READ  #x64617461)
(define STDERR_WRITE #x64617416)
(define STDERR_LAST  #x616c7473)
(define STDERR_ERROR #x63787470)
