;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build outputs)
  #:use-module ((gxd references) #:select (scan-nar))
  #:use-module ((gxd store-files) #:select (canonicalize-metadata!))
  #:use-module ((guix build utils) #:select (false-if-file-not-found))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception))
  #:export (canonicalize-output! prepare-output! &missing-output-error missing-output-error?
                                 missing-output-error-drv-path missing-output-error-output-path
                                 &output-permission-error output-permission-error?
                                 output-permission-error-output-path))

(define-exception-type &missing-output-error &error
  make-missing-output-error missing-output-error?
  (drv-path missing-output-error-drv-path)
  (output-path missing-output-error-output-path))

(define-exception-type &output-permission-error &error
  make-output-permission-error output-permission-error?
  (output-path output-permission-error-output-path))

(define (canonicalize-output! drv-path output-path actual-path)
  "Validate and canonicalize ACTUAL-PATH produced for DRV-PATH's OUTPUT-PATH.
Use declared OUTPUT-PATH in output rejection errors.  The caller holds the output
lock, excludes concurrent GC, and prevents concurrent modification of the output.
The output is owned by the caller."
  (define info (false-if-file-not-found (lstat actual-path)))

  ;; A successful builder must have produced the declared output.
  (unless info
    (raise-exception (make-missing-output-error drv-path output-path)))

  ;; Group/world write permission permits interference by other users.  Reject
  ;; it before canonicalization removes those bits; symlink mode is irrelevant.
  (when (and (not (eq? 'symlink (stat:type info)))
             (not (zero? (logand (stat:perms info) #o022))))
    (raise-exception (make-output-permission-error output-path)))

  (canonicalize-metadata! actual-path))

(define (prepare-output! drv-path output-path candidates)
  "Validate and canonicalize ordinary OUTPUT-PATH produced by DRV-PATH.
Return its references, NAR SHA-256 bytevector and NAR size from `scan-nar',
using CANDIDATES.  The caller holds the output lock, excludes concurrent GC,
and prevents concurrent modification of the output.  The output is owned by
the caller."
  (canonicalize-output! drv-path output-path output-path)
  (scan-nar output-path candidates))
