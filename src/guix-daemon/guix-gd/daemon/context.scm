;;; Shared per-connection mutable context.

(define-module (guix-gd daemon context)
  #:use-module (ice-9 threads) ; make-mutex, with-mutex
  #:export (make-connection-context
            with-context-lock
            context-set-client-version!
            context-client-minor
            context-daemon-mode
            context-set-daemon-mode!
            context-begin-op!
            context-await-reply!
            context-finish-op!
            context-current-op-code
            context-current-op-name))

;; One connection has exactly two relay threads.  They need to share only a few
;; facts: the client protocol version, the current operation, and whether the
;; daemon-side decoder should treat the next bytes as control frames or as an
;; opaque reply payload.
;;
;; Vector layout:
;;   0: mutex (short for mutual exclusion)
;;   1: client version or #f
;;   2: client minor version or #f
;;   3: current operation code or #f
;;   4: current operation name or #f
;;   5: daemon decode mode: one of 'handshake, 'wait-op, 'frames, 'reply,
;;      'ignore-reply

(define (make-connection-context)
  "Return mutable shared state for one relayed client connection."
  (vector (make-mutex) #f #f #f #f 'handshake))

(define (with-context-lock ctx thunk)
  "Call THUNK while holding the mutex stored in CTX."
  (with-mutex (vector-ref ctx 0)
    (thunk)))

(define (context-set-client-version! ctx version)
  "Store client protocol VERSION in CTX."
  (with-context-lock
   ctx
   (lambda ()
     (vector-set! ctx 1 version)
     (vector-set! ctx 2 (logand version #xff)))))

(define (context-client-minor ctx)
  "Return the stored client protocol minor version, or `#f`."
  (with-context-lock ctx (lambda () (vector-ref ctx 2))))

(define (context-daemon-mode ctx)
  "Return the daemon decoder mode stored in CTX."
  (with-context-lock ctx (lambda () (vector-ref ctx 5))))

(define (context-set-daemon-mode! ctx mode)
  "Set the daemon decoder MODE in CTX."
  (with-context-lock ctx (lambda () (vector-set! ctx 5 mode))))

(define (context-begin-op! ctx code name)
  "Record that operation CODE/NAME is now waiting for daemon frames."
  (with-context-lock
   ctx
   (lambda ()
     (vector-set! ctx 3 code)
     (vector-set! ctx 4 name)
     (vector-set! ctx 5 'frames))))

(define (context-await-reply! ctx)
  "Record that daemon control frames ended and a normal reply is expected next."
  (with-context-lock ctx (lambda () (vector-set! ctx 5 'reply))))

(define (context-finish-op! ctx)
  "Record that the current operation and its reply are fully consumed."
  (with-context-lock
   ctx
   (lambda ()
     (vector-set! ctx 3 #f)
     (vector-set! ctx 4 #f)
     (vector-set! ctx 5 'wait-op))))

(define (context-current-op-code ctx)
  "Return the current operation code stored in CTX, or `#f`."
  (with-context-lock ctx (lambda () (vector-ref ctx 3))))

(define (context-current-op-name ctx)
  "Return the current operation name stored in CTX, or `#f`."
  (with-context-lock ctx (lambda () (vector-ref ctx 4))))
