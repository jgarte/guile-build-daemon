;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay)
  #:use-module ((ice-9 exceptions) #:select (raise-exception))
  #:use-module ((gxd testbox)
                #:select (start-testbox-process! testbox-manifest testbox-root))
  #:use-module (gxd test-prelude)
  #:use-module ((gxd testbox-relay observer)
                #:select (make-relay-observer read-next-connection-bytes!))
  #:export (client-trust-fixture paired-relay-observers-fixture))

;; The box owns the relay process.  This fixture owns its host-side sockets;
;; only the client endpoint and the existing observer cross the scope boundary.

(define daemon-socket "/var/guix/daemon-socket/socket")
(define relay-socket "/tmp/gxd-relay.sock")
(define observation-socket "/tmp/gxd-relay-observation.sock")

(define (client-trust-fixture trusted?)
  "Return a fixture that preserves context and publishes TRUSTED?."
  (lambda (ctx proceed)
    (proceed (acons 'client/trusted? trusted? ctx) (lambda () #t))))

(define (require-context ctx key)
  "Return CTX's value under KEY, including #f; raise if absent."
  (let ((entry (assq key ctx)))
    (if entry (cdr entry) (error "missing relay fixture context" key))))

(define (call-with-testbox-relay box role proc)
  "Call PROC with a host endpoint and observer for BOX's relay running as ROLE.
Release host sockets on exit; BOX owns and reaps the relay process."
  (let* ((source (get (testbox-manifest box) 'testbox/relay-src))
         (endpoint (string-append (testbox-root box) relay-socket))
         (observation-path (string-append (testbox-root box) observation-socket))
         (bound? #f)
         (observation #f))
    (define listener (socket AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))

    (dynamic-wind
      (lambda () #t)
      (lambda ()
        ;; The selected nonroot role must reach the host's observation socket.
        (let ((parent (dirname observation-path)))
          (unless (file-exists? parent) (mkdir parent))
          (chmod parent #o1777))
        (bind listener AF_UNIX observation-path)
        (set! bound? #t)
        (chmod observation-path #o666)
        (listen listener 1)

        ;; The box owns the process; this scope owns its observation connection.
        (start-testbox-process!
         box role (canonicalize-path (require-program "guix"))
         (list "repl" "-L" (string-append source "/../..") "--"
               (string-append source "/relay.scm")
               relay-socket daemon-socket observation-socket))

        ;; Accept the relay's readiness connection, not a daemon client probe.
        (unless (memq listener (car (select (list listener) '() '() 20)))
          (error "timed out waiting for relay observation connection" endpoint))
        (set! observation (car (accept listener)))
        (close-port listener)
        (proc endpoint (make-relay-observer observation)))
      (lambda ()
        ;; Release every acquired resource, even when an earlier close fails.
        (let ((failure #f))
          (define (attempt thunk)
            (let ((raised (capture-exception thunk)))
              (unless failure (set! failure raised))))

          (attempt (lambda () (when observation (close-port observation))))
          (attempt (lambda ()
                     (unless (port-closed? listener) (close-port listener))))
          ;; A failed bind does not give us ownership of an existing pathname.
          (attempt (lambda () (when bound? (delete-file observation-path))))
          (when failure (raise-exception failure)))))))

(define paired-relay-observers-fixture
  (lambda (ctx proceed)
    "Preserve CTX and add relay/left-endpoint, relay/right-endpoint (host paths),
and relay/left-observer, relay/right-observer (live observers).
Add observe-bytes!, which consumes one completed connection per side and
returns (LEFT-BYTES RIGHT-BYTES) within a shared 20-second observation deadline.
Require testbox/left, testbox/right and client/trusted?."
    (let ((left-box (require-context ctx 'testbox/left))
          (right-box (require-context ctx 'testbox/right))
          (role (if (require-context ctx 'client/trusted?) 'daemon 'user)))
      (call-with-testbox-relay
       left-box role
       (lambda (left-endpoint left-observer)
         (call-with-testbox-relay
          right-box role
          (lambda (right-endpoint right-observer)
            (define (observe-bytes!)
              (let* ((deadline (+ 20 (current-time)))
                     (left (read-next-connection-bytes! left-observer deadline))
                     (right (read-next-connection-bytes! right-observer deadline)))
                (list left right)))

            (proceed `((observe-bytes! . ,observe-bytes!)
                       (relay/left-endpoint . ,left-endpoint)
                       (relay/right-endpoint . ,right-endpoint)
                       (relay/left-observer . ,left-observer)
                       (relay/right-observer . ,right-observer)
                       ,@ctx)
                     (lambda () #t)))))))))
