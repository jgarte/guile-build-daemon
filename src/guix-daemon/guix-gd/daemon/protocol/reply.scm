;;; Operation reply payload decoders.
;;;
;;; Once daemon control frames finish with STDERR_LAST, the stream contains an
;;; operation-specific reply payload.  The current operation code is tracked in
;;; shared connection context and used here to select a reply parser.
;;;
;;; Parsers intentionally summarize data for logging (counts/booleans/sizes)
;;; instead of materializing full payloads, to keep logs readable and avoid
;;; excessive overhead in the relay path.

(define-module (guix-gd daemon protocol reply)
  #:use-module (guix-gd daemon context)
  #:use-module (guix-gd daemon protocol primitives)
  #:use-module (guix-gd daemon protocol client)
  #:export (parse-reply-no-payload
            parse-reply-boolean
            parse-reply-string
            parse-reply-string-list
            parse-reply-find-roots
            parse-reply-collect-garbage
            parse-reply-query-substitutable-path-info
            parse-reply-path-info
            parse-reply-query-substitutable-path-infos
            reply-parser-table
            find-reply-parser
            parse-current-op-reply-at))

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
                (let ((obsolete-result
                       (parse-longlong-at bv (parsed-next freed-result))))
                  (and obsolete-result
                       (parsed `((paths-count . ,(length (parsed-value paths-result)))
                                 (bytes-freed . ,(parsed-value freed-result))
                                 (obsolete . ,(parsed-value obsolete-result)))
                               (parsed-next obsolete-result)))))))))

(define (parse-reply-query-substitutable-path-info bv start client-minor)
  "Parse a `wopQuerySubstitutablePathInfo` reply payload.

Layout starts with a presence integer.  If absent, no more fields follow."
  (let ((present-result (parse-int-at bv start)))
    (and present-result
         (if (= 0 (parsed-value present-result))
             (parsed '((present? . #f))
                     (parsed-next present-result))
             (let* ((deriver-result
                     (parse-string-at bv (parsed-next present-result)))
                    (refs-result
                     (and deriver-result
                          (parse-string-list-at bv (parsed-next deriver-result))))
                    (dl-result
                     (and refs-result
                          (parse-longlong-at bv (parsed-next refs-result)))))
               (and dl-result
                    (if (and client-minor (>= client-minor 7))
                        (let ((nar-result
                               (parse-longlong-at bv (parsed-next dl-result))))
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
  "Parse a `wopQuerySubstitutablePathInfos` reply payload.

Each item contributes path metadata; logs only keep the overall item count."
  (let ((count-result (parse-int-at bv start)))
    (and count-result
         (let loop ((remaining (parsed-value count-result))
                    (index (parsed-next count-result)))
           (if (= remaining 0)
               (parsed `((count . ,(parsed-value count-result)))
                       index)
               (let* ((path-result (parse-string-at bv index))
                      (deriver-result
                       (and path-result
                            (parse-string-at bv (parsed-next path-result))))
                      (refs-result
                       (and deriver-result
                            (parse-string-list-at bv (parsed-next deriver-result))))
                      (dl-result
                       (and refs-result
                            (parse-longlong-at bv (parsed-next refs-result))))
                      (nar-result
                       (and dl-result
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
  "Parse one full daemon reply payload for the current operation in CTX.

Return shape:
  (reply CODE NAME DETAILS NEXT)
  (unsupported CODE NAME START)
  (no-op START)

`unsupported` and `no-op` let observers degrade gracefully to raw relay mode
without throwing exceptions."
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
