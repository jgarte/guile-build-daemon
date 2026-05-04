;;; Incremental protocol observers used for structured relay logging.

(define-module (guix-gd daemon observer)
  #:use-module (guix-gd daemon constants)
  #:use-module (guix-gd daemon context)
  #:use-module (guix-gd daemon logging)
  #:use-module (guix-gd daemon protocol)
  #:use-module (ice-9 format)
  #:use-module (rnrs bytevectors)
  #:export (make-client-decoder-state
            make-daemon-decoder-state
            observe-client-bytevector!
            observe-daemon-bytevector!))

;; Client decoder state vector layout:
;;   0: phase symbol
;;   1: buffered unread bytes

(define (make-client-decoder-state)
  "Return fresh client-side decoder state for one connection."
  (vector 'client-magic (make-bytevector 0)))

(define (make-daemon-decoder-state)
  "Return fresh daemon-side decoder state for one connection."
  (vector 'daemon-greeting (make-bytevector 0)))

(define (disable-client-decoder! state reason)
  "Disable structured client decoding in STATE and log REASON."
  (vector-set! state 0 'client-opaque)
  (vector-set! state 1 (make-bytevector 0))
  (log "client -> daemon [decode disabled] ~a~%" reason))

(define (disable-daemon-decoder! ctx state reason)
  "Disable structured daemon decoding in STATE and log REASON."
  (vector-set! state 0 'daemon-opaque)
  (vector-set! state 1 (make-bytevector 0))
  (context-set-daemon-mode! ctx 'ignore-reply)
  (log "daemon -> client [decode disabled] ~a~%" reason))

(define (drain-client-buffer! ctx state)
  "Consume complete client handshake fields and requests buffered in STATE."
  (let loop ()
    (let ((phase (vector-ref state 0))
          (buffer (vector-ref state 1)))
      (case phase
        ((client-magic)
         (let ((result (parse-int-at buffer 0)))
           (when result
             (let ((magic (parsed-value result)))
               (log "client -> daemon [handshake] magic=0x~x~%" magic)
               (vector-set! state 1 (drop-bytevector-prefix buffer (parsed-next result)))
               (if (= magic WORKER_MAGIC_1)
                   (begin
                     (vector-set! state 0 'client-version)
                     (loop))
                   (disable-client-decoder! state "unexpected client magic"))))))
        ((client-version)
         (let ((result (parse-int-at buffer 0)))
           (when result
             (let ((version (parsed-value result))
                   (next (parsed-next result)))
               (context-set-client-version! ctx version)
               (log "client -> daemon [handshake] version=0x~x minor=~a~%"
                    version
                    (logand version #xff))
               (vector-set! state 1 (drop-bytevector-prefix buffer next))
               (if (>= (logand version #xff) 14)
                   (vector-set! state 0 'client-affinity-flag)
                   (if (>= (logand version #xff) 11)
                       (vector-set! state 0 'client-reserve-space)
                       (vector-set! state 0 'client-ops)))
               (loop)))))
        ((client-affinity-flag)
         (let ((result (parse-bool-at buffer 0)))
           (when result
             (let ((enabled? (parsed-value result)))
               (log "client -> daemon [handshake] cpu-affinity? ~a~%" enabled?)
               (vector-set! state 1 (drop-bytevector-prefix buffer (parsed-next result)))
               (vector-set! state 0 (if enabled?
                                        'client-affinity-value
                                        'client-reserve-space))
               (loop)))))
        ((client-affinity-value)
         (let ((result (parse-int-at buffer 0)))
           (when result
             (log "client -> daemon [handshake] cpu-affinity=~a~%"
                  (parsed-value result))
             (vector-set! state 1 (drop-bytevector-prefix buffer (parsed-next result)))
             (vector-set! state 0 'client-reserve-space)
             (loop))))
        ((client-reserve-space)
         (let ((result (parse-bool-at buffer 0)))
           (when result
             (log "client -> daemon [handshake] reserve-space=~a~%"
                  (parsed-value result))
             (vector-set! state 1 (drop-bytevector-prefix buffer (parsed-next result)))
             (vector-set! state 0 'client-ops)
             (loop))))
        ((client-ops)
         (let ((event (parse-client-operation-at buffer
                                                 0
                                                 (or (context-client-minor ctx) 0))))
           (when event
             (if (eq? (car event) 'known)
                 (let ((code (list-ref event 1))
                       (name (list-ref event 2))
                       (details (list-ref event 3))
                       (next (list-ref event 4)))
                   (log "client -> daemon [op] ~a (~a)~a~%"
                        code name (details->string details))
                   (context-begin-op! ctx code name)
                   (vector-set! state 1 (drop-bytevector-prefix buffer next))
                   (loop))
                 (let ((code (list-ref event 1))
                       (name (list-ref event 2)))
                   ;; Unknown payload layouts do not break the relay.  They only
                   ;; mean we can no longer stay synchronised enough to decode
                   ;; later client requests safely.
                   (log "client -> daemon [op] ~a (~a) [unknown payload; raw relay continues]~%"
                        code name)
                   (context-begin-op! ctx code name)
                   (disable-client-decoder! state
                                            "unsupported client request payload"))))))
        ((client-opaque)
         #t)
        (else
         (disable-client-decoder! state "unknown client decoder state"))))))

(define (observe-client-bytevector! ctx state chunk count)
  "Feed COUNT bytes from CHUNK into the client-side structured decoder."
  (catch #t
    (lambda ()
      (unless (eq? (vector-ref state 0) 'client-opaque)
        (vector-set! state 1
                     (append-bytevector-slice (vector-ref state 1) chunk count))
        (drain-client-buffer! ctx state)))
    (lambda args
      (disable-client-decoder! state (format #f "exception: ~s" args)))))

(define (drain-daemon-handshake! ctx state)
  "Consume complete daemon handshake fields already buffered in STATE."
  (let loop ()
    (let ((buffer (vector-ref state 1)))
      (cond
       ((eq? (vector-ref state 0) 'daemon-greeting)
        (let ((magic-result (parse-int-at buffer 0)))
          (when magic-result
            (let ((version-result (parse-int-at buffer (parsed-next magic-result))))
              (when version-result
                (log "daemon -> client [handshake] magic=0x~x version=0x~x~%"
                     (parsed-value magic-result)
                     (parsed-value version-result))
                (vector-set! state 1
                             (drop-bytevector-prefix buffer
                                                     (parsed-next version-result)))
                (vector-set! state 0 'daemon-startup)
                (loop))))))
       ((eq? (vector-ref state 0) 'daemon-startup)
        (let ((result (parse-int-at buffer 0)))
          (when result
            (log "daemon -> client [handshake] startup-frame=0x~x~%"
                 (parsed-value result))
            (vector-set! state 1
                         (drop-bytevector-prefix buffer (parsed-next result)))
            (vector-set! state 0 'daemon-stream)
            (context-set-daemon-mode! ctx 'wait-op)
            (loop))))
       (else
        #t)))))

(define (drain-daemon-frames! ctx state)
  "Consume complete daemon control frames already buffered in STATE."
  (let loop ()
    (let ((buffer (vector-ref state 1))
          (client-minor (context-client-minor ctx))
          (op-name-now (context-current-op-name ctx)))
      (let ((event (parse-daemon-frame-at buffer 0 client-minor)))
        (when event
          (case (car event)
            ((next)
             (log "daemon -> client [frame ~a] STDERR_NEXT ~a~%"
                  (or op-name-now "unknown-op")
                  (string-preview (cadr event)))
             (vector-set! state 1 (drop-bytevector-prefix buffer (caddr event)))
             (loop))
            ((read)
             (log "daemon -> client [frame ~a] STDERR_READ max-len=~a~%"
                  (or op-name-now "unknown-op")
                  (cadr event))
             (vector-set! state 1 (drop-bytevector-prefix buffer (caddr event)))
             (loop))
            ((write)
             (log "daemon -> client [frame ~a] STDERR_WRITE len=~a~%"
                  (or op-name-now "unknown-op")
                  (cadr event))
             (vector-set! state 1 (drop-bytevector-prefix buffer (caddr event)))
             (loop))
            ((error)
             (log "daemon -> client [frame ~a] STDERR_ERROR message=~a~@[ status=~a~]~%"
                  (or op-name-now "unknown-op")
                  (string-preview (cadr event))
                  (caddr event))
             (vector-set! state 1 (make-bytevector 0))
             (context-finish-op! ctx))
            ((last)
             (log "daemon -> client [frame ~a] STDERR_LAST~%"
                  (or op-name-now "unknown-op"))
             (vector-set! state 1 (drop-bytevector-prefix buffer (caddr event)))
             (context-await-reply! ctx)
             (drain-daemon-replies! ctx state))
            ((unknown)
             (log "daemon -> client [frame ~a] unknown-control=0x~x; raw relay continues~%"
                  (or op-name-now "unknown-op")
                  (cadr event))
             (vector-set! state 1 (make-bytevector 0))
             (context-set-daemon-mode! ctx 'ignore-reply))))))))

(define (drain-daemon-replies! ctx state)
  "Consume a complete daemon reply payload for the current operation."
  (let* ((buffer (vector-ref state 1))
         (client-minor (context-client-minor ctx))
         (op-name-now (or (context-current-op-name ctx) "unknown-op"))
         (event (parse-current-op-reply-at ctx buffer 0 client-minor)))
    (cond
     ((not event)
      #f)
     ((eq? (car event) 'reply)
      (log "daemon -> client [reply ~a]~a~%"
           (list-ref event 2)
           (details->string (list-ref event 3)))
      (vector-set! state 1
                   (drop-bytevector-prefix buffer (list-ref event 4)))
      (context-finish-op! ctx)
      #t)
     ((eq? (car event) 'unsupported)
      (log "daemon -> client [reply ~a] unsupported reply parser; continuing raw relay~%"
           (list-ref event 2))
      (vector-set! state 1 (make-bytevector 0))
      (context-set-daemon-mode! ctx 'ignore-reply)
      #t)
     ((eq? (car event) 'no-op)
      (log "daemon -> client [reply] no current op in context; falling back to raw relay~%")
      (vector-set! state 1 (make-bytevector 0))
      (context-set-daemon-mode! ctx 'ignore-reply)
      #t)
     (else
      (log "daemon -> client [reply ~a] unexpected decoder event=~s~%"
           op-name-now event)
      (vector-set! state 1 (make-bytevector 0))
      (context-set-daemon-mode! ctx 'ignore-reply)
      #t))))

(define (observe-daemon-bytevector! ctx state chunk count)
  "Feed COUNT bytes from CHUNK into the daemon-side structured decoder."
  (catch #t
    (lambda ()
      (let ((phase (vector-ref state 0)))
        (cond
         ((eq? phase 'daemon-opaque)
          #t)
         ((or (eq? phase 'daemon-greeting)
              (eq? phase 'daemon-startup))
          (vector-set! state 1
                       (append-bytevector-slice (vector-ref state 1)
                                                chunk
                                                count))
          (drain-daemon-handshake! ctx state))
         (else
          (case (context-daemon-mode ctx)
            ((wait-op ignore-reply)
             ;; Bytes in these phases are intentionally opaque to the
             ;; structured decoder.  They are still fully relayed by the
             ;; raw forwarder.
             #t)
            ((frames)
             (vector-set! state 1
                          (append-bytevector-slice (vector-ref state 1)
                                                   chunk
                                                   count))
             (drain-daemon-frames! ctx state))
            ((reply)
             (vector-set! state 1
                          (append-bytevector-slice (vector-ref state 1)
                                                   chunk
                                                   count))
             (drain-daemon-replies! ctx state))
            (else
             (disable-daemon-decoder! ctx state
                                      "unknown daemon decode mode")))))))
    (lambda args
      (disable-daemon-decoder! ctx state
                               (format #f "exception: ~s" args)))))
