;;; Client-request decoders for the worker protocol.
;;;
;;; After the initial client handshake, the request stream is a sequence of
;;; operations:
;;;
;;;   [op-code:int64][op-specific payload bytes]
;;;
;;; This module maps op-codes to small payload parsers that only extract fields
;;; useful for logs (counts, key flags, selected strings).  Unknown operations
;;; intentionally remain non-fatal: higher layers switch to raw relay mode.

(define-module (guix-gd daemon protocol client)
  #:use-module (guix-gd daemon protocol primitives)
  #:export (advance-with
            advance-n
            advance-string-pairs
            parse-noarg-request
            parse-string-request
            parse-string-list-request
            parse-build-paths-request
            parse-path-status-request
            parse-set-options-request
            parse-collect-garbage-request
            parse-clear-failed-request
            parse-verify-store-request
            op-table
            find-op-entry
            op-name
            parse-client-operation-at))

;; ---------- Parser flow helpers ----------
;;
;; A lot of request fields are version-gated and not interesting on their own.
;; These helpers let us "consume and advance" without deeply nested lets.

(define (advance-with parser bv index)
  "Parse one value with PARSER at INDEX and return the next index."
  (let ((result (parser bv index)))
    (and result (parsed-next result))))

(define (advance-n parser bv index count)
  "Advance INDEX by parsing COUNT values with PARSER."
  (let loop ((remaining count)
             (current index))
    (if (= remaining 0)
        current
        (let ((next (advance-with parser bv current)))
          (and next
               (loop (- remaining 1) next))))))

(define (advance-string-pairs bv index count)
  "Advance INDEX over COUNT pairs of worker-protocol strings."
  (let loop ((remaining count)
             (current index))
    (if (= remaining 0)
        current
        (let ((name-result (parse-string-at bv current)))
          (and name-result
               (let ((value-result (parse-string-at bv (parsed-next name-result))))
                 (and value-result
                      (loop (- remaining 1)
                            (parsed-next value-result)))))))))

;; ---------- Request payload parsers ----------

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
  "Parse a `wopBuildPaths` request.

Protocol minor >= 15 appends one extra build mode integer."
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

`wopSetOptions` is one of the most version-sensitive requests.  The daemon
still expects old compatibility fields for some minor ranges, so even when we
ignore a field semantically, we must consume it byte-for-byte to stay aligned.

Notable version gates (mirrors nix-daemon.cc behavior):
  - < #x61: legacy max-jobs/max-silent-time fields present
  - >= 2:   use-substitutes flag
  - >= 4:   extra verbosity/time-trace fields
  - >= 6 and < #x61: legacy build-timeout field
  - >= 10:  use-cores flag
  - >= 12:  extra-settings string-pair map"
  (let* ((keep-failed-result (parse-bool-at bv start))
         (keep-going-result
          (and keep-failed-result
               (parse-bool-at bv (parsed-next keep-failed-result))))
         (build-fallback-result
          (and keep-going-result
               (parse-bool-at bv (parsed-next keep-going-result))))
         (verbosity-result
          (and build-fallback-result
               (parse-int-at bv (parsed-next build-fallback-result))))
         (index-after-verbosity
          (and verbosity-result
               (parsed-next verbosity-result)))

         ;; Old protocol variants carry two extra integers after verbosity.
         (index-after-legacy-counts
          (and index-after-verbosity
               (if (< client-minor #x61)
                   (advance-n parse-int-at bv index-after-verbosity 2)
                   index-after-verbosity)))

         ;; `use-substitutes` flag appears in minor >= 2.
         (index-after-use-substitutes
          (and index-after-legacy-counts
               (if (>= client-minor 2)
                   (advance-with parse-bool-at bv index-after-legacy-counts)
                   index-after-legacy-counts)))

         ;; Minor >= 4 adds two ints and one bool related to build verbosity.
         (index-after-build-verbosity
          (and index-after-use-substitutes
               (if (>= client-minor 4)
                   (let ((index-after-two-ints
                          (advance-n parse-int-at bv index-after-use-substitutes 2)))
                     (and index-after-two-ints
                          (advance-with parse-bool-at bv index-after-two-ints)))
                   index-after-use-substitutes)))

         ;; Extra legacy timeout field exists only in a narrow version window.
         (index-after-build-timeout
          (and index-after-build-verbosity
               (if (and (>= client-minor 6)
                        (< client-minor #x61))
                   (advance-with parse-int-at bv index-after-build-verbosity)
                   index-after-build-verbosity)))

         ;; Minor >= 10 includes an extra bool (`use-cores`).
         (index-after-use-cores
          (and index-after-build-timeout
               (if (>= client-minor 10)
                   (advance-with parse-bool-at bv index-after-build-timeout)
                   index-after-build-timeout))))
    (and index-after-use-cores
         (if (>= client-minor 12)
             (let ((count-result (parse-int-at bv index-after-use-cores)))
               (and count-result
                    (let ((index-after-settings
                           (advance-string-pairs bv
                                                 (parsed-next count-result)
                                                 (parsed-value count-result))))
                      (and index-after-settings
                           (parsed `((keep-failed . ,(parsed-value keep-failed-result))
                                     (keep-going . ,(parsed-value keep-going-result))
                                     (build-fallback . ,(parsed-value build-fallback-result))
                                     (verbosity . ,(parsed-value verbosity-result))
                                     (extra-settings . ,(parsed-value count-result)))
                                   index-after-settings)))))
             (parsed `((keep-failed . ,(parsed-value keep-failed-result))
                       (keep-going . ,(parsed-value keep-going-result))
                       (build-fallback . ,(parsed-value build-fallback-result))
                       (verbosity . ,(parsed-value verbosity-result))
                       (extra-settings . 0))
                     index-after-use-cores)))))

(define (parse-collect-garbage-request bv start client-minor)
  "Parse a `wopCollectGarbage` request.

Minor >= 5 appends two legacy integers that must be consumed for alignment."
  (let* ((action-result (parse-int-at bv start))
         (paths-result
          (and action-result
               (parse-string-list-at bv (parsed-next action-result))))
         (ignore-result
          (and paths-result
               (parse-bool-at bv (parsed-next paths-result))))
         (max-freed-result
          (and ignore-result
               (parse-longlong-at bv (parsed-next ignore-result))))
         (obsolete-result
          (and max-freed-result
               (parse-int-at bv (parsed-next max-freed-result))))
         (index-after-obsolete
          (and obsolete-result
               (parsed-next obsolete-result)))
         (index-after-legacy-fields
          (and index-after-obsolete
               (if (>= client-minor 5)
                   (advance-n parse-int-at bv index-after-obsolete 2)
                   index-after-obsolete))))
    (and index-after-legacy-fields
         (parsed `((action . ,(parsed-value action-result))
                   (paths-to-delete-count . ,(length (parsed-value paths-result)))
                   (ignore-liveness . ,(parsed-value ignore-result))
                   (max-freed . ,(parsed-value max-freed-result)))
                 index-after-legacy-fields))))

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
   (list 1  "wopIsValidPath"                 parse-string-request)
   (list 3  "wopHasSubstitutes"              parse-string-request)
   (list 4  "wopQueryPathHash"               parse-string-request)
   (list 5  "wopQueryReferences"             parse-string-request)
   (list 6  "wopQueryReferrers"              parse-string-request)
   (list 9  "wopBuildPaths"                  parse-build-paths-request)
   (list 10 "wopEnsurePath"                  parse-path-status-request)
   (list 11 "wopAddTempRoot"                 parse-path-status-request)
   (list 12 "wopAddIndirectRoot"             parse-path-status-request)
   (list 13 "wopSyncWithGC"                  parse-noarg-request)
   (list 18 "wopQueryDeriver"                parse-string-request)
   (list 19 "wopSetOptions"                  parse-set-options-request)
   (list 20 "wopCollectGarbage"              parse-collect-garbage-request)
   (list 21 "wopQuerySubstitutablePathInfo"  parse-string-request)
   (list 22 "wopQueryDerivationOutputs"      parse-string-request)
   (list 23 "wopQueryAllValidPaths"          parse-noarg-request)
   (list 24 "wopQueryFailedPaths"            parse-noarg-request)
   (list 25 "wopClearFailedPaths"            parse-clear-failed-request)
   (list 26 "wopQueryPathInfo"               parse-string-request)
   (list 28 "wopQueryDerivationOutputNames"  parse-string-request)
   (list 29 "wopQueryPathFromHashPart"       parse-string-request)
   (list 30 "wopQuerySubstitutablePathInfos" parse-string-list-request)
   (list 31 "wopQueryValidPaths"             parse-string-list-request)
   (list 32 "wopQuerySubstitutablePaths"     parse-string-list-request)
   (list 33 "wopQueryValidDerivers"          parse-string-request)
   (list 34 "wopOptimiseStore"               parse-noarg-request)
   (list 35 "wopVerifyStore"                 parse-verify-store-request)
   (list 80 "wopBuiltinBuilders"             parse-noarg-request)
   (list 81 "wopSubstituteURLs"              parse-noarg-request)))

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

Return shape:
  (known CODE NAME DETAILS NEXT)
  (unknown CODE NAME NEXT)

When the operation code is known but payload bytes are incomplete, return `#f`
so the incremental observer can wait for more bytes."
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
