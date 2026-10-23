;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build realization)
  #:use-module (gxd prelude)
  #:use-module ((gxd build execution) #:select (execute-builder!))
  #:use-module ((gxd build inputs) #:select (reference-candidates))
  #:use-module ((gxd build outputs) #:select (prepare-output!))
  #:use-module ((gxd derivations) #:select (read-derivation))
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
  #:use-module ((srfi srfi-1) #:select (any every filter))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (realize-derivation! realize-path!))

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

(define (realize-path! db store-directory drv-path build-directory-parent cores log!)
  "Realize registered DRV-PATH and its required input outputs.
Build all outputs when selected outputs are missing.  BUILD-DIRECTORY-PARENT,
CORES and LOG! follow `realize-derivation!'.  The caller excludes concurrent
invalidation."
  (define (realize-input! input)
    (realize-selected! (guix-drv:derivation-input-derivation input)
                       (guix-drv:derivation-input-sub-derivations input)))

  (define (realize-selected! path output-names)
    (if (requested-outputs-valid? db path output-names)
        'already-valid
        (let ((drv (call-with-input-file path read-derivation)))
          (for-each realize-input! (guix-drv:derivation-inputs drv))
          (realize-derivation! db store-directory path drv
                               build-directory-parent cores log!))))

  (realize-selected! drv-path '()))

(define (build-and-register! db store-directory drv-path drv output-paths build-directory-parent cores log!)
  (define candidates (reference-candidates db drv-path drv))

  (for-each delete-path! output-paths)
  (define build-directory (mkdtemp! (string-append build-directory-parent "/build.XXXXXX")))

  (call-with-cleanup
   (lambda () (delete-path! build-directory))
   (lambda ()
     (define status (execute-builder! drv store-directory build-directory cores log!))
     (define exit-code (status:exit-val status))

     (unless (and exit-code (zero? exit-code))
       (error "builder failed" drv-path status))

     (define output-infos
       (map (lambda (output-path)
              (let-values (((references hash nar-size)
                            (prepare-output! drv-path output-path candidates)))
                (database:make-output-info output-path hash nar-size references)))
            output-paths))

     (database:register-outputs! db store-directory drv-path output-infos)
     'built)))

(define (realize-derivation! db store-directory drv-path drv build-directory-parent cores log!)
  "Realize admitted ordinary DRV at DRV-PATH with already-realized inputs.
Use DB and STORE-DIRECTORY for acceptance and create a temporary workspace under
existing BUILD-DIRECTORY-PARENT.  Advertise CORES to the builder and deliver its
binary log chunks to LOG!.  Return `already-valid' or `built'.
DRV has distinct output paths.  Input derivations in DRV are represented by
filenames, not resolved derivation records.  The caller excludes concurrent GC;
execution is same-owner and unsandboxed.  Failed builds may leave
unregistered output files; temporary build directories are removed."
  (define outputs (guix-drv:derivation-outputs drv))
  (define output-paths
    (map (match-lambda ((_ . output) (guix-drv:derivation-output-path output))) outputs))

  (when (any (match-lambda ((_ . output) (guix-drv:derivation-output-hash output))) outputs)
    (todo! "fixed-output realization" drv-path))

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
            (build-and-register! db store-directory drv-path drv output-paths
                                 build-directory-parent cores log!)))))))
