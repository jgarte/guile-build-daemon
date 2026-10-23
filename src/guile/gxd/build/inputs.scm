;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build inputs)
  #:use-module (gxd prelude)
  #:use-module ((gxd database)
                #:prefix database:
                #:select (derivation-outputs reference-closure))
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (derivation-inputs derivation-sources derivation-outputs
                                            derivation-output-path derivation-input-derivation
                                            derivation-input-sub-derivations))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((ice-9 match) #:select (match-lambda))
  #:use-module ((srfi srfi-1) #:select (append-map delete-duplicates))
  #:export (reference-candidates
            &missing-input-output missing-input-output?
            missing-input-output-drv-path missing-input-output-input-path
            missing-input-output-name missing-input-output-message))

(define-exception-type &missing-input-output &error
  make-missing-input-output missing-input-output?
  (drv-path missing-input-output-drv-path)
  (input-path missing-input-output-input-path)
  (name missing-input-output-name))

(define (missing-input-output-message exception)
  (format #f "derivation `~a' requires non-existent output `~a' from input derivation `~a'"
          (missing-input-output-drv-path exception)
          (missing-input-output-name exception)
          (missing-input-output-input-path exception)))

(define (reject-missing-output drv-path input-path output-name)
  (raise-exception (make-missing-input-output drv-path input-path output-name)))

(define (input-output-paths db drv-path input)
  "Return INPUT's requested output paths from DB, rejecting missing output names."
  (define input-path (guix-drv:derivation-input-derivation input))
  (define output-paths-by-name (database:derivation-outputs db input-path))

  (map
   (lambda (output-name)
     (or (assoc-ref output-paths-by-name output-name)
         (reject-missing-output drv-path input-path output-name)))
   (guix-drv:derivation-input-sub-derivations input)))

(define (reference-candidates db drv-path drv)
  "Return the sorted unique paths that DRV's outputs may reference.
Include all own outputs and the DB reference closure of input sources and
selected input outputs.  DRV-PATH names DRV for diagnostics; DRV is decoded
with input derivation filenames, not resolved records.  Inputs are realized
and the caller excludes concurrent invalidation."
  (let* ((selected-input-output-paths
          (append-map (lambda (input) (input-output-paths db drv-path input))
                      (guix-drv:derivation-inputs drv)))
         (input-paths (append selected-input-output-paths (guix-drv:derivation-sources drv)))
         (input-closure (database:reference-closure db input-paths))
         (own-output-paths
          (map (match-lambda ((_ . output) (guix-drv:derivation-output-path output)))
               (guix-drv:derivation-outputs drv))))
    (chain (append own-output-paths input-closure)
      (delete-duplicates _ string=?)
      (sort _ string<?))))
