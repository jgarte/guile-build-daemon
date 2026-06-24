;;; Guix daemon relay and protocol logger.
;;;
;;; This module no longer pretends to be a daemon.  Instead, it listens on one
;;; UNIX socket, connects to a fallback `guix-daemon` on another socket, and
;;; relays bytes in both directions.
;;;
;;; Implementation is split across small modules:
;;;   - (guix-gd daemon logging)
;;;   - (guix-gd daemon context)
;;;   - (guix-gd daemon protocol) façade, plus:
;;;       * (guix-gd daemon protocol primitives)
;;;       * (guix-gd daemon protocol client)
;;;       * (guix-gd daemon protocol daemon)
;;;       * (guix-gd daemon protocol reply)
;;;       * (guix-gd daemon protocol constants)
;;;   - (guix-gd daemon observer)
;;;   - (guix-gd daemon relay)

(define-module (guix-gd daemon daemon)
  #:use-module (guix-gd daemon logging)
  #:use-module (guix-gd daemon relay)
  ;; Re-import parser primitives so existing tests using
  ;; (@@ (guix-gd daemon daemon) <parser>) keep working.
  #:use-module (guix-gd daemon protocol)
  #:export (main))

;; By default the relay listens on the normal Guix daemon socket.  This matches
;; the intended deployment: the relay becomes the daemon visible to clients,
;; while the real daemon is moved to a non-default fallback socket.
(define default-listen-socket-path "/var/guix/daemon-socket/socket")
(define default-upstream-socket-path "/tmp/guix-gd-fallback.sock")

(define (main args)
  "Listen on a socket and relay clients to a fallback daemon.

CLI:
  guix-gd-daemon [LISTEN-SOCKET [UPSTREAM-SOCKET]]

Defaults:
  LISTEN-SOCKET   => `/var/guix/daemon-socket/socket`
  UPSTREAM-SOCKET => `/tmp/guix-gd-fallback.sock`"
  (let* ((listen-path (if (> (length args) 1)
                          (list-ref args 1)
                          default-listen-socket-path))
         (upstream-path (if (> (length args) 2)
                            (list-ref args 2)
                            default-upstream-socket-path)))
    (ensure-listen-path-free listen-path)
    (let ((server (socket AF_UNIX SOCK_STREAM 0)))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (bind server AF_UNIX listen-path)
          (listen server 5)
          (log "listening on: ~a~%" listen-path)
          (log "upstream: ~a~%" upstream-path)
          (log "example: guix gc --list-dead~%")
          (serve-forever server upstream-path))
        (lambda ()
          (close-safely server)
          (when (file-exists? listen-path)
            (false-if-exception (delete-file listen-path))))))))
