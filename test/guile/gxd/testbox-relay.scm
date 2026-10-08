;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay)
  #:use-module ((ares suitbl fixture) #:select ((compose . compose-fixtures)))
  #:use-module ((ice-9 exceptions) #:select (raise-exception with-exception-handler))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((srfi srfi-197) #:select (chain))
  #:use-module ((gxd testbox)
                #:select (start-testbox-process! testbox-manifest testbox-root))
  #:use-module (gxd test-prelude)
  #:use-module ((gxd testbox-relay observer)
                #:select (make-relay-observer read-next-connection-bytes!))
  #:export (client-trust-fixture relay-observer-fixture paired-relay-observers-fixture))

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

(define (start-testbox-relay box role)
  "Return (ENDPOINT OBSERVER TEARDOWN!) for BOX's relay running as ROLE.
BOX owns and reaps the relay process; TEARDOWN! releases host sockets."
  (let* ((source (get (testbox-manifest box) 'testbox/relay-src))
         (endpoint (string-append (testbox-root box) relay-socket))
         (observation-path (string-append (testbox-root box) observation-socket))
         (bound? #f)
         (observation #f))
    (define listener (socket AF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0))

    (define (teardown!)
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
        (when failure (raise-exception failure))))

    (with-exception-handler
        (lambda (exception)
          (false-if-exception (teardown!))
          (raise-exception exception))
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
        (list endpoint (make-relay-observer observation) teardown!))
      #:unwind? #t)))

(define (relay-observer-fixture side)
  "Return a fixture publishing SIDE's relay endpoint and observer.
SIDE is 'left or 'right; require its testbox and client/trusted? in context."
  (match-let (((box-key endpoint-key observer-key)
               (case side
                 ((left) '(testbox/left relay/left-endpoint relay/left-observer))
                 ((right) '(testbox/right relay/right-endpoint relay/right-observer))
                 (else (error "unknown relay side" side)))))
    (lambda (ctx proceed)
      (let ((box (require-context ctx box-key))
            (role (if (require-context ctx 'client/trusted?) 'daemon 'user)))
        (match-let (((endpoint observer release!) (start-testbox-relay box role)))
          (define active? #t)
          (define (teardown!)
            (when active?
              (set! active? #f)
              (release!)))

          (with-exception-handler
              (lambda (exception)
                (false-if-exception (teardown!))
                (raise-exception exception))
            (lambda ()
              (proceed (acons endpoint-key endpoint (acons observer-key observer ctx))
                       teardown!))
            #:unwind? #t))))))

(define (paired-observations-fixture ctx proceed)
  "Add observe-bytes! over CTX's two observers, sharing a 20-second deadline."
  (let ((left-observer (require-context ctx 'relay/left-observer))
        (right-observer (require-context ctx 'relay/right-observer)))
    (define (observe-bytes!)
      (let* ((deadline (+ 20 (current-time)))
             (left (read-next-connection-bytes! left-observer deadline))
             (right (read-next-connection-bytes! right-observer deadline)))
        (list left right)))

    (proceed (acons 'observe-bytes! observe-bytes! ctx) (lambda () #t))))

(define paired-relay-observers-fixture
  (chain (relay-observer-fixture 'left)
         (compose-fixtures _ (relay-observer-fixture 'right))
         (compose-fixtures _ paired-observations-fixture)))
