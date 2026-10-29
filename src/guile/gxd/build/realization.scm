;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build realization)
  #:use-module (gxd prelude)
  #:use-module ((gxd build config)
                #:select (build-store-directory build-directory-parent build-sandboxed?
                          build-use-substitutes? build-options))
  #:use-module ((gxd build substitutes)
                #:select (substitute-path! &substitution-failure))
  #:use-module ((gxd session) #:select (options-fallback?))
  #:use-module ((gxd build execution) #:select (execute-builder! execute-download!))
  #:use-module ((gxd build inputs) #:select (reference-candidates input-closure))
  #:use-module ((gxd build outputs)
                #:select (prepare-output! prepare-sandboxed-output! preserve-failed-output!
                          missing-output-error? missing-output-error-drv-path
                          missing-output-error-output-path output-permission-error?
                          output-permission-error-output-path
                          flat-output-type-error? flat-output-type-error-output-path
                          output-hash-mismatch? output-hash-mismatch-output-path))
  #:use-module ((gxd derivations) #:select (read-derivation fixed-output drv->output-paths))
  #:use-module ((gxd build sandbox) #:select (call-with-build-sandbox sandbox-root))
  #:use-module ((gxd database)
                #:prefix database:
                #:select (valid-path? make-output-info register-outputs! derivation-outputs))
  #:use-module ((gxd path-locks) #:select (call-with-destination-locks))
  #:use-module ((gxd store-files) #:select (delete-path!))
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (derivation-outputs derivation-output-path derivation-output-hash derivation-builder
                          derivation-inputs derivation-input-derivation
                          derivation-builder-environment-vars
                          derivation-input-sub-derivations))
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module ((ice-9 match) #:select (match-lambda))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception with-exception-handler))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:use-module ((system foreign) #:select (int pointer->procedure pointer->string))
  #:use-module ((srfi srfi-1) #:select (every filter))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (realize-derivation! realize-path!
                                &builder-exit-error builder-exit-error? builder-exit-error-derivation
                                builder-exit-error-status builder-exit-error-fixed-output?
                                derivation-substitution-error? derivation-substitution-error-path))

(define-exception-type &derivation-substitution-error &error
  make-derivation-substitution-error derivation-substitution-error?
  (path derivation-substitution-error-path)
  (cause derivation-substitution-error-cause))

(define-exception-type &builder-exit-error &error
  make-builder-exit-error builder-exit-error?
  (derivation builder-exit-error-derivation)
  (status builder-exit-error-status)
  (fixed-output? builder-exit-error-fixed-output?))

(define signal-description
  (pointer->procedure '* (dynamic-func "strsignal" (dynamic-link)) (list int)))

(define (status-description status)
  (cond
   ((status:exit-val status)
    => (lambda (code) (format #f "failed with exit code ~a" code)))
   ((status:term-sig status)
    => (lambda (signal)
         (format #f "failed due to signal ~a (~a)"
                 signal (pointer->string (signal-description signal)))))
   (else "died abnormally")))

(define (requested-outputs-valid? db drv-path output-names)
  "Return whether DRV-PATH's declared outputs selected by OUTPUT-NAMES are valid.
An empty selection requests all outputs.  Absent names are diagnosed later by
the consuming derivation's reference-candidate check."
  (every
   (match-lambda
     ((name . path)
      (if (or (null? output-names) (member name output-names))
          (database:valid-path? db path)
          #t)))
   (database:derivation-outputs db drv-path)))

(define (selected-output-paths db path names)
  (map cdr
       (filter (match-lambda
                 ((name . _) (or (null? names) (member name names))))
               (database:derivation-outputs db path))))

(define (call-with-substitution-fallback drv-path fallback? thunk)
  "Call THUNK, returning #f on substitution failure when FALLBACK? is true.
Otherwise raise a substitution error identifying DRV-PATH."
  (with-exception-handler
    (lambda (exception)
      (if fallback?
          #f
          (raise-exception (make-derivation-substitution-error drv-path exception))))
    thunk
    #:unwind? #t
    #:unwind-for-type &substitution-failure))

(define (substitute-outputs! db drv-path drv output-names config)
  "Substitute DRV's selected OUTPUT-NAMES when CONFIG and DRV permit it.
Return 'substituted on success, 'incomplete-closure to realize inputs and retry,
or #f to continue toward building."
  (let* ((environment (guix-drv:derivation-builder-environment-vars drv))
         (allow-substitutes (assoc-ref environment "allowSubstitutes")))
    (and (build-use-substitutes? config)
         (or (not allow-substitutes) (string=? allow-substitutes "1"))
         (call-with-substitution-fallback drv-path (options-fallback? (build-options config))
           (lambda ()
             (define outcomes
               (map (lambda (path) (substitute-path! db path config))
                    (selected-output-paths db drv-path output-names)))

             (cond
              ((every (lambda (outcome) (eq? outcome 'satisfied)) outcomes)
               'substituted)
              ((memq 'incomplete-closure outcomes) 'incomplete-closure)
              (else #f)))))))

(define* (realize-path! db drv-path config log! #:optional (output-names '()))
  "Realize registered DRV-PATH's OUTPUT-NAMES and its required input outputs.
An empty selection requests all outputs.  Build all outputs when selected
outputs are missing.
The caller excludes concurrent invalidation."

  (define (realize-inputs! drv)
    (for-each
     (lambda (input)
       (realize-path! db (guix-drv:derivation-input-derivation input) config log!
                      (guix-drv:derivation-input-sub-derivations input)))
     (guix-drv:derivation-inputs drv)))

  (if (requested-outputs-valid? db drv-path output-names)
      'already-valid
      (let ((drv (call-with-input-file drv-path read-derivation)))
        (case (substitute-outputs! db drv-path drv output-names config)
          ((substituted) 'substituted)
          ((incomplete-closure)
           (realize-inputs! drv)
           (realize-path! db drv-path config log! output-names))
          (else
           (realize-inputs! drv)
           (realize-derivation! db drv-path drv config log!))))))

(define (call-with-output-error-logging log! thunk)
  "Call THUNK, logging output rejection diagnostics through LOG! before re-raising."
  (with-exception-handler
    (lambda (exception)
      (define diagnostic
        (cond
         ((missing-output-error? exception)
          (format #f "builder for `~a' failed to produce output path `~a'"
                  (missing-output-error-drv-path exception)
                  (missing-output-error-output-path exception)))
         ((output-permission-error? exception)
          (format #f "suspicious ownership or permission on `~a'; rejecting this build output"
                  (output-permission-error-output-path exception)))
         ((flat-output-type-error? exception)
          (format #f "output path `~a' should be a non-executable regular file"
                  (flat-output-type-error-output-path exception)))
         ((output-hash-mismatch? exception)
          (format #f "hash mismatch for store item '~a'"
                  (output-hash-mismatch-output-path exception)))
         (else (raise-exception exception))))

      (log! (string->utf8 (string-append diagnostic "\n")))
      (raise-exception exception))
    thunk
    #:unwind? #t))

(define (preserve-failed-outputs! output-paths sandbox-root-directory log!)
  "Move failed OUTPUT-PATHS out of SANDBOX-ROOT-DIRECTORY, logging errors to LOG!."
  (for-each
   (lambda (output-path)
     (with-exception-handler
       (lambda (exception)
         (log! (string->utf8
                (format #f "failed to preserve output `~a': ~s~%" output-path exception))))
       (lambda ()
         (preserve-failed-output! output-path (string-append sandbox-root-directory output-path)))
       #:unwind? #t))
   output-paths))

(define (download-builder? drv)
  (member (guix-drv:derivation-builder drv) '("builtin:download" "builtin:git-download")))

(define (build-and-prepare-outputs! db drv-path drv build-directory
                                    output-paths config log! sandbox)
  "Execute DRV, prepare OUTPUT-PATHS, and return their metadata for registration.
Preserve failed sandbox outputs before reporting the builder's failure."
  (define candidates (reference-candidates db drv-path drv))

  (define status
    (if (download-builder? drv)
        (let ((output-path (guix-drv:derivation-output-path
                            (assoc-ref (guix-drv:derivation-outputs drv) "out"))))
          (execute-download! drv-path output-path build-directory config log!))
        (execute-builder! drv build-directory sandbox config log!)))

  (define exit-code (status:exit-val status))
  (define fixed-output? (if (fixed-output drv) #t #f))

  (unless (and exit-code (zero? exit-code))
    (when sandbox
      (preserve-failed-outputs! output-paths (sandbox-root sandbox) log!))
    (log! (string->utf8
           (format #f "builder for `~a' ~a~%" drv-path (status-description status))))
    (raise-exception (make-builder-exit-error drv-path status fixed-output?)))

  (define (prepare-output-info output)
    (define output-path (guix-drv:derivation-output-path output))

    (let-values (((references hash nar-size)
                  (if sandbox
                      (prepare-sandboxed-output!
                       drv-path output candidates
                       (string-append (sandbox-root sandbox) output-path))
                      (prepare-output! drv-path output candidates))))
      (database:make-output-info output-path hash nar-size references)))

  (call-with-output-error-logging log!
    (lambda () (map prepare-output-info (map cdr (guix-drv:derivation-outputs drv))))))

(define (build-and-register! db drv-path drv config log!)
  "Build DRV and register its outputs, owning temporary workspace and sandbox cleanup.
The caller holds the output locks; CONFIG supplies execution settings."
  (define output-paths (drv->output-paths drv))

  (for-each delete-path! output-paths)
  (define build-directory (mkdtemp! (string-append (build-directory-parent config) "/build.XXXXXX")))

  (call-with-cleanup
   (lambda () (delete-path! build-directory))
   (lambda ()
     (define (build! sandbox)
       (build-and-prepare-outputs! db drv-path drv build-directory
                                   output-paths config log! sandbox))

     (define output-infos
       (if (and (build-sandboxed? config) (not (download-builder? drv)))
           (call-with-build-sandbox drv-path (build-store-directory config)
                                    (input-closure db drv-path drv) 30001 30000
                                    build!)
           (build! #f)))

     (database:register-outputs! db (build-store-directory config) drv-path output-infos)
     'built)))

(define (realize-derivation! db drv-path drv config log!)
  "Realize admitted DRV at DRV-PATH with already-realized inputs.
Use DB for acceptance and CONFIG for execution settings and workspace location.  Deliver
binary log chunks to LOG!.  Return `already-valid' or `built'.
DRV has distinct output paths.  Input derivations in DRV are represented by
filenames, not resolved derivation records.  The caller excludes concurrent GC;
execution is same-owner.  Failed builds may leave
unregistered output files; temporary build directories are removed."
  (define output-paths (drv->output-paths drv))

  (define (valid-output? path) (database:valid-path? db path))

  (if (every valid-output? output-paths)
      'already-valid
      (call-with-destination-locks output-paths
        (lambda ()
          (define valid-output-paths (filter valid-output? output-paths))

          (cond
           ((= (length valid-output-paths) (length output-paths)) 'already-valid)
           ((pair? valid-output-paths)
            ;; Non-chroot nixd redirects valid siblings and rewrites references.
            (todo! "partially valid output realization" drv-path))
           (else
            (build-and-register! db drv-path drv config log!)))))))
