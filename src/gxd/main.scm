;;; Guix daemon relay and protocol logger.
;;;
;;; This module no longer pretends to be a daemon.  Instead, it listens on one
;;; UNIX socket, connects to a fallback `guix-daemon` on another socket, and
;;; relays bytes in both directions.
;;;
;;; Implementation is split across small modules:
;;;   - (gxd logging)
;;;   - (gxd context)
;;;   - (gxd protocol) façade, plus:
;;;       * (gxd protocol primitives)
;;;       * (gxd protocol client)
;;;       * (gxd protocol daemon)
;;;       * (gxd protocol reply)
;;;       * (gxd protocol constants)
;;;   - (gxd observer)
;;;   - (gxd relay)

(define-module (gxd main)
  #:use-module (gxd logging)
  #:use-module (gxd relay)
  ;; Re-import parser primitives so existing tests using
  ;; (@@ (gxd main) <parser>) keep working.
  #:use-module (gxd protocol)
  #:export (main))

;; By default the relay listens on the normal Guix daemon socket.  This matches
;; the intended deployment: the relay becomes the daemon visible to clients,
;; while the real daemon is moved to a non-default fallback socket.
(define default-listen-socket-path "/var/guix/daemon-socket/socket")
(define default-upstream-socket-path "/tmp/gxd-fallback.sock")

(define (main args)
  "Listen on a socket and relay clients to a fallback daemon.

CLI:
  gxd [LISTEN-SOCKET [UPSTREAM-SOCKET]]

Defaults:
  LISTEN-SOCKET   => `/var/guix/daemon-socket/socket`
  UPSTREAM-SOCKET => `/tmp/gxd-fallback.sock`"
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
