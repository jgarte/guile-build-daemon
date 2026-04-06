;;; Minimal Guix guile daemon listener.

(define-module (guix-gd daemon)
  #:use-module (ice-9 format)       ; format
  #:use-module (ice-9 binary-ports) ; get-bytevector-n, put-bytevector
  #:use-module (rnrs bytevectors)   ; bytevector-{u32,u64}-{ref,set!}, utf8 helpers
  #:use-module (rnrs io ports)      ; force-output
  #:export (main))

(define default-socket-path "/tmp/guix-gd-daemon.sock")

;; worker-protocol.hh
(define WORKER_MAGIC_1 #x6e697863)
(define WORKER_MAGIC_2 #x6478696f)
(define PROTOCOL_VERSION #x0164)

;; worker-protocol.hh: daemon control frames sent before normal op reply payload.
(define STDERR_LAST  #x616c7473)

;; ---------- Binary protocol helpers (serialise.cc compatible) ----------

(define (read-exactly port n)
  (let ((bv (get-bytevector-n port n)))
    (cond
     ((eof-object? bv) bv)
     ((< (bytevector-length bv) n)
      (error "Unexpected EOF while reading bytes" n (bytevector-length bv)))
     (else bv))))

;; serialise.cc readInt/writeInt: 8 bytes on wire, low 32 bits used.
(define (read-int port)
  (let ((bv (read-exactly port 8)))
    (if (eof-object? bv)
        bv
        (let ((lo (bytevector-u32-ref bv 0 (endianness little)))
              (hi (bytevector-u32-ref bv 4 (endianness little))))
          (when (not (= hi 0))
            (error "Protocol int > 32-bit not supported" hi))
          lo))))

(define (write-int port n)
  (let ((bv (make-bytevector 8 0)))
    (bytevector-u32-set! bv 0 n (endianness little))
    (put-bytevector port bv)))

(define (read-longlong port)
  (let ((bv (read-exactly port 8)))
    (if (eof-object? bv)
        bv
        (bytevector-u64-ref bv 0 (endianness little)))))

(define (write-longlong port n)
  (let ((bv (make-bytevector 8 0)))
    (bytevector-u64-set! bv 0 n (endianness little))
    (put-bytevector port bv)))

(define (read-padding port len)
  (let ((pad (modulo (- 8 (modulo len 8)) 8)))
    (when (> pad 0)
      (let ((bv (read-exactly port pad)))
        (when (eof-object? bv)
          (error "Unexpected EOF in padding"))))))

;; serialise.cc readString/writeString
(define (read-string port)
  (let ((len (read-int port)))
    (if (eof-object? len)
        len
        (let ((data (read-exactly port len)))
          (read-padding port len)
          (utf8->string data)))))

(define (write-string port s)
  (let* ((bv (string->utf8 s))
         (len (bytevector-length bv))
         (pad (modulo (- 8 (modulo len 8)) 8)))
    (write-int port len)
    (put-bytevector port bv)
    (when (> pad 0)
      (put-bytevector port (make-bytevector pad 0)))))

(define (read-string-list port)
  (let ((count (read-int port)))
    (if (eof-object? count)
        count
        (let loop ((n count) (acc '()))
          (if (= n 0)
              (reverse acc)
              (loop (- n 1) (cons (read-string port) acc)))))))

(define (write-string-list port strings)
  (write-int port (length strings))
  (for-each (lambda (s) (write-string port s)) strings))

(define (read-bool port)
  (not (= 0 (read-int port))))

(define (send-success port)
  ;; nix-daemon.cc stopWork(success=true)
  (write-int port STDERR_LAST))

;; ---------- Parsers used by specific operations ----------

(define (parse-set-options port client-minor)
  ;; nix-daemon.cc: case wopSetOptions
  (let ((keep-failed    (read-bool port))
        (keep-going     (read-bool port))
        (build-fallback (read-bool port))
        (verbosity      (read-int port)))

    (when (< client-minor #x61)
      (read-int port) ; build-max-jobs
      (read-int port)) ; build-max-silent-time

    (when (>= client-minor 2)  (read-bool port))
    (when (>= client-minor 4)
      (read-int port) ; build-verbosity
      (read-int port) ; log-type
      (read-bool port))
    (when (and (>= client-minor 6) (< client-minor #x61))
      (read-int port)) ; build-cores
    (when (>= client-minor 10) (read-bool port))

    (let ((extra-count
           (if (>= client-minor 12)
               (let ((n (read-int port)))
                 (let loop ((i n))
                   (if (= i 0)
                       n
                       (begin
                         (read-string port) ; name
                         (read-string port) ; value
                         (loop (- i 1))))))
               0)))
      `((keep-failed . ,keep-failed)
        (keep-going . ,keep-going)
        (build-fallback . ,build-fallback)
        (verbosity . ,verbosity)
        (extra-settings . ,extra-count)))))

(define (parse-collect-garbage port client-minor)
  ;; nix-daemon.cc: case wopCollectGarbage
  (let ((action (read-int port))
        (paths-to-delete (read-string-list port))
        (ignore-liveness (read-bool port))
        (max-freed (read-longlong port)))
    (read-int port) ; obsolete
    (when (>= client-minor 5)
      (read-int port) ; removed option
      (read-int port)) ; removed option
    `((action . ,action)
      (paths-to-delete-count . ,(length paths-to-delete))
      (ignore-liveness . ,ignore-liveness)
      (max-freed . ,max-freed))))

;; ---------- Per-op handlers ----------

(define (h-bool-false-from-string port client-minor)
  (let ((s (read-string port)))
    (format #t "   arg: ~s~%" s)
    (send-success port)
    (write-int port 0)))

(define (h-empty-string-from-string port client-minor)
  (let ((s (read-string port)))
    (format #t "   arg: ~s~%" s)
    (send-success port)
    (write-string port "")))

(define (h-empty-list-from-string port client-minor)
  (let ((s (read-string port)))
    (format #t "   arg: ~s~%" s)
    (send-success port)
    (write-string-list port '())))

(define (h-empty-list-from-list port client-minor)
  (let ((paths (read-string-list port)))
    (format #t "   paths-count: ~a~%" (length paths))
    (send-success port)
    (write-string-list port '())))

(define (h-build-paths port client-minor)
  (let ((drvs (read-string-list port)))
    (when (>= client-minor 15)
      (read-int port)) ; build mode
    (format #t "   drv-count: ~a~%" (length drvs))
    (send-success port)
    (write-int port 1)))

(define (h-path-status1 port client-minor)
  (let ((p (read-string port)))
    (format #t "   path: ~s~%" p)
    (send-success port)
    (write-int port 1)))

(define (h-noarg-status1 port client-minor)
  (send-success port)
  (write-int port 1))

(define (h-noarg-empty-list port client-minor)
  (send-success port)
  (write-string-list port '()))

(define (h-set-options port client-minor)
  (let ((args (parse-set-options port client-minor)))
    (format #t "   set-options: ~s~%" args)
    ;; Real daemon sends only STDERR_LAST for this op.
    (send-success port)))

(define (h-collect-garbage port client-minor)
  (let ((args (parse-collect-garbage port client-minor)))
    (format #t "   collect-garbage: ~s~%" args)
    (send-success port)
    (write-string-list port '())
    (write-longlong port 0)
    (write-longlong port 0)))

(define (h-clear-failed port client-minor)
  (let ((paths (read-string-list port)))
    (format #t "   clear-failed paths-count: ~a~%" (length paths))
    (send-success port)
    (write-int port 1)))

(define (h-verify-store port client-minor)
  (let ((check-contents (read-bool port))
        (repair (read-bool port)))
    (format #t "   verify-store: check-contents=~a repair=~a~%" check-contents repair)
    (send-success port)
    (write-int port 0)))

;; ---------- Dispatch table (replaces case + separate wop alist) ----------
;; Entry format: (opcode name handler)
;; opcode values from worker-protocol.hh; payload shapes from nix-daemon.cc.
(define op-table
  (list
   (list 1  "wopIsValidPath"               h-bool-false-from-string)
   (list 3  "wopHasSubstitutes"            h-bool-false-from-string)
   (list 4  "wopQueryPathHash"             h-empty-string-from-string)
   (list 5  "wopQueryReferences"           h-empty-list-from-string)
   (list 6  "wopQueryReferrers"            h-empty-list-from-string)
   (list 9  "wopBuildPaths"                h-build-paths)
   (list 10 "wopEnsurePath"                h-path-status1)
   (list 11 "wopAddTempRoot"               h-path-status1)
   (list 12 "wopAddIndirectRoot"           h-path-status1)
   (list 13 "wopSyncWithGC"                h-noarg-status1)
   (list 18 "wopQueryDeriver"              h-empty-string-from-string)
   (list 19 "wopSetOptions"                h-set-options)
   (list 20 "wopCollectGarbage"            h-collect-garbage)
   (list 21 "wopQuerySubstitutablePathInfo" h-empty-list-from-string)
   (list 22 "wopQueryDerivationOutputs"    h-empty-list-from-string)
   (list 23 "wopQueryAllValidPaths"        h-noarg-empty-list)
   (list 24 "wopQueryFailedPaths"          h-noarg-empty-list)
   (list 25 "wopClearFailedPaths"          h-clear-failed)
   (list 26 "wopQueryPathInfo"             h-empty-list-from-string)
   (list 28 "wopQueryDerivationOutputNames" h-empty-list-from-string)
   (list 29 "wopQueryPathFromHashPart"     h-empty-string-from-string)
   (list 30 "wopQuerySubstitutablePathInfos" h-empty-list-from-list)
   (list 31 "wopQueryValidPaths"           h-empty-list-from-list)
   (list 32 "wopQuerySubstitutablePaths"   h-empty-list-from-list)
   (list 33 "wopQueryValidDerivers"        h-empty-list-from-string)
   (list 34 "wopOptimiseStore"             h-noarg-status1)
   (list 35 "wopVerifyStore"               h-verify-store)
   (list 80 "wopBuiltinBuilders"           h-noarg-empty-list)
   (list 81 "wopSubstituteURLs"            h-noarg-empty-list)))

(define (find-op-entry code)
  (let loop ((xs op-table))
    (cond
     ((null? xs) #f)
     ((= code (car (car xs))) (car xs))
     (else (loop (cdr xs))))))

(define (op-name code)
  (let ((entry (find-op-entry code)))
    (if entry (cadr entry) "unknown-wop")))

(define (dispatch-op port op client-minor)
  (let ((entry (find-op-entry op)))
    (if (not entry)
        (error "Unsupported opcode (no parser in table)" op)
        ((caddr entry) port client-minor))))

;; ---------- Connection handling ----------

(define (handle-connection client-port)
  (format #t "Client connected. Waiting for handshake...~%")
  (let ((magic (read-int client-port)))
    (cond
     ((eof-object? magic)
      (format #t "Client disconnected before handshake.~%"))

     ((not (= magic WORKER_MAGIC_1))
      (format #t "Error: invalid client magic: 0x~x~%" magic))

     (else
      ;; nix-daemon.cc processConnection()
      (write-int client-port WORKER_MAGIC_2)
      (write-int client-port PROTOCOL_VERSION)
      (force-output client-port)

      (let* ((client-version (read-int client-port))
             (client-minor (logand client-version #xff)))
        (format #t "<- client version: 0x~x (minor=~a)~%" client-version client-minor)

        ;; protocol >= 1.14: bool + optional cpu index
        (when (>= client-minor 14)
          (when (read-bool client-port)
            (format #t "<- client cpu affinity: ~a~%" (read-int client-port))))

        ;; protocol >= 1.11: reserve-space bool
        (when (>= client-minor 11)
          (format #t "<- reserve-space: ~a~%" (read-bool client-port)))

        ;; initial startup completion frame (stopWork success)
        (send-success client-port)
        (force-output client-port)

        (format #t "Handshake complete. Waiting for operations...~%")

        (let loop ()
          (let ((op (read-int client-port)))
            (if (eof-object? op)
                (format #t "Client disconnected.~%")
                (begin
                  (format #t "<- Op: ~a (~a)~%" op (op-name op))
                  (dispatch-op client-port op client-minor)
                  (force-output client-port)
                  (loop))))))))))

(define (main args)
  ;; CLI: optional socket path as first positional argument.
  (let ((socket-path (if (and (list? args) (> (length args) 1))
                         (list-ref args 1)
                         default-socket-path)))
    (when (file-exists? socket-path)
      (delete-file socket-path))

    (let ((server (socket AF_UNIX SOCK_STREAM 0)))
      (bind server AF_UNIX socket-path)
      (listen server 5)

      (format #t "Listening on ~a~%" socket-path)
      (format #t "Try: GUIX_DAEMON_SOCKET=~a guix gc --list-dead~%" socket-path)

      (let* ((accepted (accept server))
             (client-port (car accepted)))
        (dynamic-wind
          (lambda () #t)
          (lambda () (handle-connection client-port))
          (lambda ()
            (format #t "Closing client connection.~%")
            (close-port client-port)
            (close-port server)))))))
