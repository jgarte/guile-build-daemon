;;; Guix daemon relay and protocol logger.
;;;
;;; This module no longer pretends to be a daemon.  Instead, it listens on one
;;; UNIX socket, connects to a fallback `guix-daemon` on another socket, and
;;; relays bytes in both directions.
;;;
;;; The relay has two layers:
;;;
;;;   1. a raw byte forwarder that keeps the connection correct;
;;;   2. best-effort protocol decoders that log the handshake, client worker
;;;      operations, and daemon control frames.
;;;
;;; The raw relay must stay simple and robust.  The structured logging is kept
;;; separate so that an unsupported message only disables decoding, not the
;;; relay itself.

(define-module (guix-gd daemon)
  #:use-module (ice-9 threads)      ; make-mutex, with-mutex, call-with-new-thread
  #:use-module (ice-9 format)       ; format
  #:use-module (ice-9 binary-ports) ; get-bytevector-some!, put-bytevector
  #:use-module (rnrs bytevectors)   ; bytevector helpers, UTF-8 helpers
  #:use-module (rnrs io ports)      ; force-output
  #:use-module (srfi srfi-1)        ; iota
  #:use-module (srfi srfi-13)       ; string-join, string-take
  #:export (main))

;; By default the relay listens on the normal Guix daemon socket.  This matches
;; the intended deployment: the relay becomes the daemon visible to clients,
;; while the real daemon is moved to a non-default fallback socket.
(define default-listen-socket-path "/var/guix/daemon-socket/socket")
(define default-upstream-socket-path "/tmp/guix-gd-fallback.sock")
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

;; ---------- Generic logging ----------

(define (log fmt . args)
  "Write one flushed log message.

Explicit flushing matters because two relay threads log concurrently and the
messages are most useful while the connection is still live." 
  (apply format #t fmt args)
  (force-output))

(define (byte->hex n)
  "Render byte N as two lowercase hex digits."
  (format #f "~2,'0x" n))

(define (byte->ascii n)
  "Render byte N as printable ASCII, or `.` for control bytes."
  (if (and (>= n 32) (<= n 126))
      (string (integer->char n))
      "."))

(define (string-preview s)
  "Return a compact one-line preview of S for logs."
  (let* ((normalised
          (list->string
           (map (lambda (ch)
                  (if (or (char=? ch #\newline)
                          (char=? ch #\return)
                          (char=? ch #\tab))
                      #\space
                      ch))
                (string->list s))))
         (trimmed (if (> (string-length normalised) string-preview-limit)
                      (string-append (string-take normalised string-preview-limit) "...")
                      normalised)))
    (format #f "~s" trimmed)))

(define (summarise-bytevector bv n)
  "Return a short hex plus ASCII preview of the first N bytes in BV."
  (let* ((limit (min n preview-limit))
         (hex (string-join
               (map (lambda (i) (byte->hex (bytevector-u8-ref bv i)))
                    (iota limit))
               " "))
         (ascii (string-join
                 (map (lambda (i) (byte->ascii (bytevector-u8-ref bv i)))
                      (iota limit))
                 "")))
    (if (> n limit)
        (format #f "~a ... |~a|" hex ascii)
        (format #f "~a |~a|" hex ascii))))

(define (details->string details)
  "Render DETAILS compactly for structured operation logs."
  (if (null? details)
      ""
      (format #f " ~s" details)))

;; ---------- Shared connection context ----------

;; One connection has exactly two relay threads.  They need to share only a few
;; facts: the client protocol version, the current operation, and whether the
;; daemon-side decoder should treat the next bytes as control frames or as an
;; opaque reply payload.
;;
;; Vector layout:
;;   0: mutex
;;   1: client version or #f
;;   2: client minor version or #f
;;   3: current operation code or #f
;;   4: current operation name or #f
;;   5: daemon decode mode: one of 'handshake, 'wait-op, 'frames, 'reply, 'ignore-reply

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

;; ---------- Bytevector helpers used by the structured decoders ----------

(define (slice-bytevector bv start count)
  "Return COUNT bytes copied from BV starting at START."
  (let ((out (make-bytevector count)))
    (bytevector-copy! bv start out 0 count)
    out))

(define (drop-bytevector-prefix bv count)
  "Return BV without its first COUNT bytes."
  (slice-bytevector bv count (- (bytevector-length bv) count)))

(define (append-bytevector-slice base chunk count)
  "Append the first COUNT bytes of CHUNK to BASE and return a fresh bytevector."
  (let* ((base-len (bytevector-length base))
         (out (make-bytevector (+ base-len count))))
    (bytevector-copy! base 0 out 0 base-len)
    (bytevector-copy! chunk 0 out base-len count)
    out))

(define (bytes-available? bv start count)
  "Return true when COUNT bytes can be read from BV starting at START."
  (>= (- (bytevector-length bv) start) count))

(define (parsed value next)
  "Pack parser VALUE with the NEXT unread byte index."
  (cons value next))

(define (parsed-value result)
  "Return the value part of parser RESULT."
  (car result))

(define (parsed-next result)
  "Return the next unread index from parser RESULT."
  (cdr result))

(define (parse-int-at bv start)
  "Parse one worker-protocol integer from BV at START.

Worker integers use eight bytes on the wire even though the low 32 bits carry
all the useful information for the cases handled here." 
  (and (bytes-available? bv start 8)
       (let ((lo (bytevector-u32-ref bv start (endianness little)))
             (hi (bytevector-u32-ref bv (+ start 4) (endianness little))))
         (if (= hi 0)
             (parsed lo (+ start 8))
             (parsed (+ lo (ash hi 32)) (+ start 8))))))

(define (parse-longlong-at bv start)
  "Parse one little-endian 64-bit integer from BV at START."
  (and (bytes-available? bv start 8)
       (parsed (bytevector-u64-ref bv start (endianness little))
               (+ start 8))))

(define (parse-bool-at bv start)
  "Parse one worker-protocol boolean from BV at START."
  (let ((result (parse-int-at bv start)))
    (and result
         (parsed (not (= 0 (parsed-value result)))
                 (parsed-next result)))))

(define (padding-size len)
  "Return the wire padding used after a LEN-byte string payload."
  (modulo (- 8 (modulo len 8)) 8))

(define (safe-utf8->string bv)
  "Decode BV as UTF-8, falling back to a readable placeholder on failure."
  (catch #t
    (lambda () (utf8->string bv))
    (lambda _
      (format #f "<non-utf8: ~a>"
              (summarise-bytevector bv (bytevector-length bv))))))

(define (parse-string-at bv start)
  "Parse one padded worker-protocol string from BV at START."
  (let ((len-result (parse-int-at bv start)))
    (and len-result
         (let* ((len (parsed-value len-result))
                (data-start (parsed-next len-result))
                (pad (padding-size len))
                (need (+ len pad)))
           (and (bytes-available? bv data-start need)
                (parsed (safe-utf8->string (slice-bytevector bv data-start len))
                        (+ data-start need)))))))

(define (parse-string-list-at bv start)
  "Parse one worker-protocol list of strings from BV at START."
  (let ((count-result (parse-int-at bv start)))
    (and count-result
         (let loop ((remaining (parsed-value count-result))
                    (index (parsed-next count-result))
                    (items '()))
           (if (= remaining 0)
               (parsed (reverse items) index)
               (let ((item-result (parse-string-at bv index)))
                 (and item-result
                      (loop (- remaining 1)
                            (parsed-next item-result)
                            (cons (parsed-value item-result) items)))))))))


(define (parse-string-pairs-at bv start)
  "Parse one worker-protocol list of string pairs from BV at START."
  (let ((count-result (parse-int-at bv start)))
    (and count-result
         (let loop ((remaining (parsed-value count-result))
                    (index (parsed-next count-result))
                    (items '()))
           (if (= remaining 0)
               (parsed (reverse items) index)
               (let ((first-result (parse-string-at bv index)))
                 (and first-result
                      (let ((second-result (parse-string-at bv (parsed-next first-result))))
                        (and second-result
                             (loop (- remaining 1)
                                   (parsed-next second-result)
                                   (cons (cons (parsed-value first-result)
                                               (parsed-value second-result))
                                         items)))))))))))

;; ---------- Client operation decoders ----------

(define (parse-noarg-request bv start client-minor)
  "Parse a request with no payload.

CLIENT-MINOR is accepted for a uniform parser signature." 
  (parsed '() start))

(define (parse-string-request bv start client-minor)
  "Parse a request whose payload is a single string." 
  (let ((result (parse-string-at bv start)))
    (and result
         (parsed `((arg . ,(parsed-value result)))
                 (parsed-next result)))))

(define (parse-string-list-request bv start client-minor)
  "Parse a request whose payload is a list of strings." 
  (let ((result (parse-string-list-at bv start)))
    (and result
         (parsed `((paths-count . ,(length (parsed-value result))))
                 (parsed-next result)))))

(define (parse-build-paths-request bv start client-minor)
  "Parse a `wopBuildPaths` request." 
  (let ((drvs-result (parse-string-list-at bv start)))
    (and drvs-result
         (let ((index (parsed-next drvs-result))
               (details `((drv-count . ,(length (parsed-value drvs-result))))))
           (if (>= client-minor 15)
               (let ((mode-result (parse-int-at bv index)))
                 (and mode-result
                      (parsed (append details
                                      `((build-mode . ,(parsed-value mode-result))))
                              (parsed-next mode-result))))
               (parsed details index))))))

(define (parse-path-status-request bv start client-minor)
  "Parse a request whose payload is one store path string." 
  (let ((result (parse-string-at bv start)))
    (and result
         (parsed `((path . ,(parsed-value result)))
                 (parsed-next result)))))

(define (parse-set-options-request bv start client-minor)
  "Parse a `wopSetOptions` request.

The parser follows `nix-daemon.cc` closely so the decoder stays aligned even
when some fields are no longer interesting to the log output." 
  (let ((keep-failed-result    (parse-bool-at bv start)))
    (and keep-failed-result
         (let ((keep-going-result     (parse-bool-at bv (parsed-next keep-failed-result))))
           (and keep-going-result
                (let ((build-fallback-result (parse-bool-at bv (parsed-next keep-going-result))))
                  (and build-fallback-result
                       (let ((verbosity-result (parse-int-at bv (parsed-next build-fallback-result))))
                         (and verbosity-result
                              (let ((index (parsed-next verbosity-result)))
                                (let ((index (if (< client-minor #x61)
                                                 (let ((r1 (parse-int-at bv index)))
                                                   (and r1
                                                        (let ((r2 (parse-int-at bv (parsed-next r1))))
                                                          (and r2 (parsed-next r2)))))
                                                 index)))
                                  (and index
                                       (let ((index (if (>= client-minor 2)
                                                        (let ((r (parse-bool-at bv index)))
                                                          (and r (parsed-next r)))
                                                        index)))
                                         (and index
                                              (let ((index (if (>= client-minor 4)
                                                               (let ((r1 (parse-int-at bv index)))
                                                                 (and r1
                                                                      (let ((r2 (parse-int-at bv (parsed-next r1))))
                                                                        (and r2
                                                                             (let ((r3 (parse-bool-at bv (parsed-next r2))))
                                                                               (and r3 (parsed-next r3)))))))
                                                               index)))
                                                (and index
                                                     (let ((index (if (and (>= client-minor 6)
                                                                           (< client-minor #x61))
                                                                      (let ((r (parse-int-at bv index)))
                                                                        (and r (parsed-next r)))
                                                                      index)))
                                                       (and index
                                                            (let ((index (if (>= client-minor 10)
                                                                             (let ((r (parse-bool-at bv index)))
                                                                               (and r (parsed-next r)))
                                                                             index)))
                                                              (and index
                                                                   (if (>= client-minor 12)
                                                                       (let ((count-result (parse-int-at bv index)))
                                                                         (and count-result
                                                                              (let loop ((remaining (parsed-value count-result))
                                                                                         (index (parsed-next count-result)))
                                                                                (if (= remaining 0)
                                                                                    (parsed `((keep-failed . ,(parsed-value keep-failed-result))
                                                                                              (keep-going . ,(parsed-value keep-going-result))
                                                                                              (build-fallback . ,(parsed-value build-fallback-result))
                                                                                              (verbosity . ,(parsed-value verbosity-result))
                                                                                              (extra-settings . ,(parsed-value count-result)))
                                                                                            index)
                                                                                    (let ((name-result (parse-string-at bv index)))
                                                                                      (and name-result
                                                                                           (let ((value-result (parse-string-at bv (parsed-next name-result))))
                                                                                             (and value-result
                                                                                                  (loop (- remaining 1)
                                                                                                        (parsed-next value-result))))))))))
                                                                       (parsed `((keep-failed . ,(parsed-value keep-failed-result))
                                                                                 (keep-going . ,(parsed-value keep-going-result))
                                                                                 (build-fallback . ,(parsed-value build-fallback-result))
                                                                                 (verbosity . ,(parsed-value verbosity-result))
                                                                                 (extra-settings . 0))
                                                                               index))))))))))))))))))))))

(define (parse-collect-garbage-request bv start client-minor)
  "Parse a `wopCollectGarbage` request." 
  (let ((action-result (parse-int-at bv start)))
    (and action-result
         (let ((paths-result (parse-string-list-at bv (parsed-next action-result))))
           (and paths-result
                (let ((ignore-result (parse-bool-at bv (parsed-next paths-result))))
                  (and ignore-result
                       (let ((max-freed-result (parse-longlong-at bv (parsed-next ignore-result))))
                         (and max-freed-result
                              (let ((obsolete-result (parse-int-at bv (parsed-next max-freed-result))))
                                (and obsolete-result
                                     (let ((index (if (>= client-minor 5)
                                                      (let ((r1 (parse-int-at bv (parsed-next obsolete-result))))
                                                        (and r1
                                                             (let ((r2 (parse-int-at bv (parsed-next r1))))
                                                               (and r2 (parsed-next r2)))))
                                                      (parsed-next obsolete-result))))
                                       (and index
                                            (parsed `((action . ,(parsed-value action-result))
                                                      (paths-to-delete-count . ,(length (parsed-value paths-result)))
                                                      (ignore-liveness . ,(parsed-value ignore-result))
                                                      (max-freed . ,(parsed-value max-freed-result)))
                                                    index))))))))))))))

(define (parse-clear-failed-request bv start client-minor)
  "Parse a `wopClearFailedPaths` request." 
  (let ((paths-result (parse-string-list-at bv start)))
    (and paths-result
         (parsed `((paths-count . ,(length (parsed-value paths-result))))
                 (parsed-next paths-result)))))

(define (parse-verify-store-request bv start client-minor)
  "Parse a `wopVerifyStore` request." 
  (let ((check-result (parse-bool-at bv start)))
    (and check-result
         (let ((repair-result (parse-bool-at bv (parsed-next check-result))))
           (and repair-result
                (parsed `((check-contents . ,(parsed-value check-result))
                          (repair . ,(parsed-value repair-result)))
                        (parsed-next repair-result)))))))

;; Entry format: (opcode name parser)
(define op-table
  (list
   (list 1  "wopIsValidPath"                parse-string-request)
   (list 3  "wopHasSubstitutes"             parse-string-request)
   (list 4  "wopQueryPathHash"              parse-string-request)
   (list 5  "wopQueryReferences"            parse-string-request)
   (list 6  "wopQueryReferrers"             parse-string-request)
   (list 9  "wopBuildPaths"                 parse-build-paths-request)
   (list 10 "wopEnsurePath"                 parse-path-status-request)
   (list 11 "wopAddTempRoot"                parse-path-status-request)
   (list 12 "wopAddIndirectRoot"            parse-path-status-request)
   (list 13 "wopSyncWithGC"                 parse-noarg-request)
   (list 18 "wopQueryDeriver"               parse-string-request)
   (list 19 "wopSetOptions"                 parse-set-options-request)
   (list 20 "wopCollectGarbage"             parse-collect-garbage-request)
   (list 21 "wopQuerySubstitutablePathInfo" parse-string-request)
   (list 22 "wopQueryDerivationOutputs"     parse-string-request)
   (list 23 "wopQueryAllValidPaths"         parse-noarg-request)
   (list 24 "wopQueryFailedPaths"           parse-noarg-request)
   (list 25 "wopClearFailedPaths"           parse-clear-failed-request)
   (list 26 "wopQueryPathInfo"              parse-string-request)
   (list 28 "wopQueryDerivationOutputNames" parse-string-request)
   (list 29 "wopQueryPathFromHashPart"      parse-string-request)
   (list 30 "wopQuerySubstitutablePathInfos" parse-string-list-request)
   (list 31 "wopQueryValidPaths"            parse-string-list-request)
   (list 32 "wopQuerySubstitutablePaths"    parse-string-list-request)
   (list 33 "wopQueryValidDerivers"         parse-string-request)
   (list 34 "wopOptimiseStore"              parse-noarg-request)
   (list 35 "wopVerifyStore"                parse-verify-store-request)
   (list 80 "wopBuiltinBuilders"            parse-noarg-request)
   (list 81 "wopSubstituteURLs"             parse-noarg-request)))

(define (find-op-entry code)
  "Return the operation table entry for CODE, or `#f`."
  (let loop ((entries op-table))
    (cond
     ((null? entries) #f)
     ((= code (car (car entries))) (car entries))
     (else (loop (cdr entries))))))

(define (op-name code)
  "Return the known worker operation name for CODE."
  (let ((entry (find-op-entry code)))
    (if entry (cadr entry) "unknown-wop")))

(define (parse-client-operation-at bv start client-minor)
  "Parse one complete client worker operation from BV at START.

The parser returns either:

  (known CODE NAME DETAILS NEXT)
  (unknown CODE NAME NEXT)

or `#f` when more bytes are needed." 
  (let ((op-result (parse-int-at bv start)))
    (and op-result
         (let* ((code (parsed-value op-result))
                (index (parsed-next op-result))
                (entry (find-op-entry code)))
           (if entry
               (let* ((name (cadr entry))
                      (parser (caddr entry))
                      (payload-result (parser bv index client-minor)))
                 (and payload-result
                      (list 'known
                            code
                            name
                            (parsed-value payload-result)
                            (parsed-next payload-result))))
               (list 'unknown code (op-name code) index))))))

;; ---------- Daemon control-frame decoders ----------

(define (parse-daemon-frame-at bv start client-minor)
  "Parse one daemon control frame from BV at START.

Only the control-frame layer is decoded here.  The ordinary operation reply
payload that follows `STDERR_LAST` remains opaque on purpose." 
  (let ((code-result (parse-int-at bv start)))
    (and code-result
         (let ((code (parsed-value code-result))
               (index (parsed-next code-result)))
           (cond
            ((= code STDERR_NEXT)
             (let ((msg-result (parse-string-at bv index)))
               (and msg-result
                    (list 'next (parsed-value msg-result) (parsed-next msg-result)))))
            ((= code STDERR_READ)
             (let ((len-result (parse-int-at bv index)))
               (and len-result
                    (list 'read (parsed-value len-result) (parsed-next len-result)))))
            ((= code STDERR_WRITE)
             (let ((len-result (parse-int-at bv index)))
               (and len-result
                    (let* ((len (parsed-value len-result))
                           (payload-start (parsed-next len-result))
                           (need (+ len (padding-size len))))
                      (and (bytes-available? bv payload-start need)
                           (list 'write len (+ payload-start need)))))))
            ((= code STDERR_ERROR)
             (let ((msg-result (parse-string-at bv index)))
               (and msg-result
                    (if (and client-minor (>= client-minor 8))
                        (let ((status-result (parse-int-at bv (parsed-next msg-result))))
                          (and status-result
                               (list 'error
                                     (parsed-value msg-result)
                                     (parsed-value status-result)
                                     (parsed-next status-result))))
                        (list 'error (parsed-value msg-result) #f (parsed-next msg-result))))))
            ((= code STDERR_LAST)
             (list 'last #f index))
            (else
             (list 'unknown code index)))))))


;; ---------- Operation reply decoders ----------

(define (parse-reply-no-payload bv start client-minor)
  "Parse a reply that has no payload bytes."
  (parsed '() start))

(define (parse-reply-boolean bv start client-minor)
  "Parse a boolean reply payload."
  (let ((result (parse-bool-at bv start)))
    (and result
         (parsed `((result . ,(parsed-value result)))
                 (parsed-next result)))))

(define (parse-reply-string bv start client-minor)
  "Parse a one-string reply payload."
  (let ((result (parse-string-at bv start)))
    (and result
         (parsed `((result . ,(parsed-value result)))
                 (parsed-next result)))))

(define (parse-reply-string-list bv start client-minor)
  "Parse a string-list reply payload."
  (let ((result (parse-string-list-at bv start)))
    (and result
         (parsed `((count . ,(length (parsed-value result))))
                 (parsed-next result)))))

(define (parse-reply-find-roots bv start client-minor)
  "Parse a `wopFindRoots` reply payload."
  (let ((result (parse-string-pairs-at bv start)))
    (and result
         (parsed `((count . ,(length (parsed-value result))))
                 (parsed-next result)))))

(define (parse-reply-collect-garbage bv start client-minor)
  "Parse a `wopCollectGarbage` reply payload."
  (let ((paths-result (parse-string-list-at bv start)))
    (and paths-result
         (let ((freed-result (parse-longlong-at bv (parsed-next paths-result))))
           (and freed-result
                (let ((obsolete-result (parse-longlong-at bv (parsed-next freed-result))))
                  (and obsolete-result
                       (parsed `((paths-count . ,(length (parsed-value paths-result)))
                                 (bytes-freed . ,(parsed-value freed-result))
                                 (obsolete . ,(parsed-value obsolete-result)))
                               (parsed-next obsolete-result)))))))))

(define (parse-reply-query-substitutable-path-info bv start client-minor)
  "Parse a `wopQuerySubstitutablePathInfo` reply payload."
  (let ((present-result (parse-int-at bv start)))
    (and present-result
         (if (= 0 (parsed-value present-result))
             (parsed '((present? . #f))
                     (parsed-next present-result))
             (let* ((deriver-result (parse-string-at bv (parsed-next present-result)))
                    (refs-result (and deriver-result
                                      (parse-string-list-at bv (parsed-next deriver-result))))
                    (dl-result (and refs-result
                                    (parse-longlong-at bv (parsed-next refs-result)))))
               (and dl-result
                    (if (and client-minor (>= client-minor 7))
                        (let ((nar-result (parse-longlong-at bv (parsed-next dl-result))))
                          (and nar-result
                               (parsed `((present? . #t)
                                         (references-count . ,(length (parsed-value refs-result)))
                                         (download-size . ,(parsed-value dl-result))
                                         (nar-size . ,(parsed-value nar-result)))
                                       (parsed-next nar-result))))
                        (parsed `((present? . #t)
                                  (references-count . ,(length (parsed-value refs-result)))
                                  (download-size . ,(parsed-value dl-result)))
                                (parsed-next dl-result)))))))))

(define (parse-reply-path-info bv start client-minor)
  "Parse a `wopQueryPathInfo` reply payload."
  (let* ((deriver-result (parse-string-at bv start))
         (hash-result (and deriver-result
                           (parse-string-at bv (parsed-next deriver-result))))
         (refs-result (and hash-result
                           (parse-string-list-at bv (parsed-next hash-result))))
         (time-result (and refs-result
                           (parse-int-at bv (parsed-next refs-result))))
         (nar-result (and time-result
                          (parse-longlong-at bv (parsed-next time-result)))))
    (and nar-result
         (parsed `((deriver . ,(parsed-value deriver-result))
                   (hash . ,(parsed-value hash-result))
                   (references-count . ,(length (parsed-value refs-result)))
                   (registration-time . ,(parsed-value time-result))
                   (nar-size . ,(parsed-value nar-result)))
                 (parsed-next nar-result)))))

(define (parse-reply-query-substitutable-path-infos bv start client-minor)
  "Parse a `wopQuerySubstitutablePathInfos` reply payload."
  (let ((count-result (parse-int-at bv start)))
    (and count-result
         (let loop ((remaining (parsed-value count-result))
                    (index (parsed-next count-result)))
           (if (= remaining 0)
               (parsed `((count . ,(parsed-value count-result)))
                       index)
               (let* ((path-result (parse-string-at bv index))
                      (deriver-result (and path-result
                                           (parse-string-at bv (parsed-next path-result))))
                      (refs-result (and deriver-result
                                        (parse-string-list-at bv (parsed-next deriver-result))))
                      (dl-result (and refs-result
                                      (parse-longlong-at bv (parsed-next refs-result))))
                      (nar-result (and dl-result
                                       (parse-longlong-at bv (parsed-next dl-result)))))
                 (and nar-result
                      (loop (- remaining 1)
                            (parsed-next nar-result)))))))))


(define reply-parser-table
  (list
   (list 1  parse-reply-boolean)
   (list 3  parse-reply-boolean)
   (list 4  parse-reply-string)
   (list 5  parse-reply-string-list)
   (list 6  parse-reply-string-list)
   (list 8  parse-reply-string)
   (list 9  parse-reply-boolean)
   (list 10 parse-reply-boolean)
   (list 11 parse-reply-boolean)
   (list 12 parse-reply-boolean)
   (list 13 parse-reply-boolean)
   (list 14 parse-reply-find-roots)
   (list 18 parse-reply-string)
   (list 19 parse-reply-no-payload)
   (list 20 parse-reply-collect-garbage)
   (list 21 parse-reply-query-substitutable-path-info)
   (list 22 parse-reply-string-list)
   (list 24 parse-reply-string-list)
   (list 25 parse-reply-boolean)
   (list 26 parse-reply-path-info)
   (list 28 parse-reply-string-list)
   (list 29 parse-reply-string)
   (list 30 parse-reply-query-substitutable-path-infos)
   (list 31 parse-reply-string-list)
   (list 32 parse-reply-string-list)
   (list 33 parse-reply-string-list)
   (list 34 parse-reply-boolean)
   (list 35 parse-reply-boolean)
   (list 80 parse-reply-string-list)
   (list 81 parse-reply-string-list)))

(define (find-reply-parser code)
  "Return the reply payload parser for operation CODE, or `#f`."
  (let loop ((entries reply-parser-table))
    (cond
     ((null? entries) #f)
     ((= code (car (car entries))) (cadr (car entries)))
     (else (loop (cdr entries))))))

(define (parse-current-op-reply-at ctx bv start client-minor)
  "Parse one full daemon reply payload for the current operation in CTX."
  (let* ((code (context-current-op-code ctx))
         (name (context-current-op-name ctx)))
    (if (not code)
        (list 'no-op start)
        (let ((parser (find-reply-parser code)))
          (if (not parser)
              (list 'unsupported code (or name (op-name code)) start)
              (let ((result (parser bv start client-minor)))
                (and result
                     (list 'reply
                           code
                           (or name (op-name code))
                           (parsed-value result)
                           (parsed-next result)))))))))

;; ---------- Incremental observers for structured logging ----------

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
         (let ((event (parse-client-operation-at buffer 0
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
                   (disable-client-decoder! state "unsupported client request payload"))))))
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
                         (drop-bytevector-prefix buffer
                                                 (parsed-next result)))
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
                                                chunk count))
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
                                                   chunk count))
             (drain-daemon-frames! ctx state))
            ((reply)
             (vector-set! state 1
                          (append-bytevector-slice (vector-ref state 1)
                                                   chunk count))
             (drain-daemon-replies! ctx state))
            (else
             (disable-daemon-decoder! ctx state
                                      "unknown daemon decode mode")))))))
    (lambda args
      (disable-daemon-decoder! ctx state
                               (format #f "exception: ~s" args)))))


;; ---------- Raw full-duplex relay ----------

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
                              client-in upstream-out upstream-socket
                              (lambda (buf n)
                                (observe-client-bytevector! ctx client-state buf n))))))
              (t2 (call-with-new-thread
                   (lambda ()
                     (forward "daemon -> client"
                              upstream-in client-out client-socket
                              (lambda (buf n)
                                (observe-daemon-bytevector! ctx daemon-state buf n)))))))
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
    (error "Listen socket path already exists; choose another path or stop the daemon using it" path)))

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
