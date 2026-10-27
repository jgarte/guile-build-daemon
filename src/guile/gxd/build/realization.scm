;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build realization)
  #:use-module (gxd prelude)
  #:use-module ((gxd build config)
                #:select (build-store-directory build-directory-parent build-cores build-sandboxed?))
  #:use-module ((gxd build execution) #:select (execute-builder!))
  #:use-module ((gxd build inputs) #:select (reference-candidates input-closure))
  #:use-module ((gxd build outputs)
                #:select (prepare-output! prepare-sandboxed-output! preserve-failed-output!
                          missing-output-error? missing-output-error-drv-path
                          missing-output-error-output-path output-permission-error?
                          output-permission-error-output-path
                          flat-output-type-error? flat-output-type-error-output-path
                          output-hash-mismatch? output-hash-mismatch-output-path))
  #:use-module ((gxd derivations) #:select (read-derivation fixed-output))
  #:use-module ((gxd build sandbox) #:select (call-with-build-sandbox sandbox-root))
  #:use-module ((gxd database)
                #:prefix database:
                #:select (valid-path? make-output-info register-outputs! derivation-outputs))
  #:use-module ((gxd path-locks) #:select (call-with-destination-locks))
  #:use-module ((gxd store-files) #:select (delete-path!))
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (derivation-outputs derivation-output-path derivation-output-hash
                          derivation-inputs derivation-input-derivation
                          derivation-input-sub-derivations))
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module ((ice-9 match) #:select (match-lambda))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception with-exception-handler))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:use-module ((system foreign) #:select (int pointer->procedure pointer->string))
  #:use-module ((srfi srfi-1) #:select (every filter find))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (realize-derivation! realize-path!
                                &builder-exit-error builder-exit-error? builder-exit-error-derivation
                                builder-exit-error-status builder-exit-error-fixed-output?))

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

(define (realize-path! db drv-path config log!)
  "Realize registered DRV-PATH and its required input outputs.
Build all outputs when selected outputs are missing.
The caller excludes concurrent invalidation."
  (define (realize-input! input)
    (realize-selected! (guix-drv:derivation-input-derivation input)
                       (guix-drv:derivation-input-sub-derivations input)))

  (define (realize-selected! path output-names)
    (if (requested-outputs-valid? db path output-names)
        'already-valid
        (let ((drv (call-with-input-file path read-derivation)))
          (for-each realize-input! (guix-drv:derivation-inputs drv))
          (realize-derivation! db path drv config log!))))

  (realize-selected! drv-path '()))

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

(define (build-and-prepare-outputs! drv-path drv build-directory
                                    output-paths candidates config log! sandbox)
  "Execute DRV, prepare OUTPUT-PATHS, and return their metadata for registration.
Preserve failed sandbox outputs before reporting the builder's failure."
  (define status (execute-builder! drv build-directory sandbox config log!))
  (define exit-code (status:exit-val status))
  (define fixed-output? (if (fixed-output drv) #t #f))

  (unless (and exit-code (zero? exit-code))
    (when sandbox
      (preserve-failed-outputs! output-paths (sandbox-root sandbox) log!))
    (log! (string->utf8
           (format #f "builder for `~a' ~a~%" drv-path (status-description status))))
    (raise-exception (make-builder-exit-error drv-path status fixed-output?)))

  (define (prepare-output-info output-path)
    (define output
      (find (lambda (output) (string=? output-path (guix-drv:derivation-output-path output)))
            (map cdr (guix-drv:derivation-outputs drv))))

    (let-values (((references hash nar-size)
                  (if sandbox
                      (prepare-sandboxed-output!
                       drv-path output candidates
                       (string-append (sandbox-root sandbox) output-path))
                      (prepare-output! drv-path output candidates))))
      (database:make-output-info output-path hash nar-size references)))

  (call-with-output-error-logging log!
    (lambda () (map prepare-output-info output-paths))))

(define (build-and-register! db drv-path drv output-paths config log!)
  "Build DRV and register its outputs, owning temporary workspace and sandbox cleanup.
The caller holds the output locks; CONFIG supplies execution settings."
  (define store-directory (build-store-directory config))
  (define candidates (reference-candidates db drv-path drv))

  (for-each delete-path! output-paths)
  (define build-directory (mkdtemp! (string-append (build-directory-parent config) "/build.XXXXXX")))

  (call-with-cleanup
   (lambda () (delete-path! build-directory))
   (lambda ()
     (define (prepare! sandbox)
       (build-and-prepare-outputs! drv-path drv build-directory
                                   output-paths candidates config log! sandbox))

     (define output-infos
       (if (build-sandboxed? config)
           (call-with-build-sandbox drv-path store-directory (input-closure db drv-path drv)
                                    30001 30000 prepare!)
           (prepare! #f)))

     (database:register-outputs! db store-directory drv-path output-infos)
     'built)))

(define (realize-derivation! db drv-path drv config log!)
  "Realize admitted DRV at DRV-PATH with already-realized inputs.
Use DB for acceptance and CONFIG for execution settings and workspace location.  Deliver
binary log chunks to LOG!.  Return `already-valid' or `built'.
DRV has distinct output paths.  Input derivations in DRV are represented by
filenames, not resolved derivation records.  The caller excludes concurrent GC;
execution is same-owner.  Failed builds may leave
unregistered output files; temporary build directories are removed."
  (define outputs (guix-drv:derivation-outputs drv))
  (define output-paths
    (map (match-lambda ((_ . output) (guix-drv:derivation-output-path output))) outputs))

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
            (build-and-register! db drv-path drv output-paths config log!)))))))
