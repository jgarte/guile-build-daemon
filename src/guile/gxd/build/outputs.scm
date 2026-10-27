;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build outputs)
  #:use-module ((gxd references) #:select (scan-nar))
  #:use-module ((gxd store-files) #:select (canonicalize-metadata! secure-file-permissions!))
  #:use-module ((gcrypt hash) #:select (lookup-hash-algorithm))
  #:use-module ((guix build utils) #:select (false-if-file-not-found))
  #:use-module ((guix derivations) #:prefix guix-drv:
                #:select (derivation-output-path derivation-output-hash
                          derivation-output-hash-algo
                          derivation-output-recursive?))
  #:use-module ((guix hash) #:select (file-hash*))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception))
  #:export (canonicalize-output! prepare-output! prepare-sandboxed-output! preserve-failed-output!
                                 &missing-output-error missing-output-error?
                                 missing-output-error-drv-path missing-output-error-output-path
                                 &output-permission-error output-permission-error?
                                 output-permission-error-output-path
                                 check-fixed-output!
                                 &flat-output-type-error flat-output-type-error?
                                 flat-output-type-error-output-path
                                 &output-hash-mismatch output-hash-mismatch?
                                 output-hash-mismatch-output-path))

(define-exception-type &missing-output-error &error
  make-missing-output-error missing-output-error?
  (drv-path missing-output-error-drv-path)
  (output-path missing-output-error-output-path))

(define-exception-type &output-permission-error &error
  make-output-permission-error output-permission-error?
  (output-path output-permission-error-output-path))

(define-exception-type &flat-output-type-error &error
  make-flat-output-type-error flat-output-type-error?
  (output-path flat-output-type-error-output-path))

(define-exception-type &output-hash-mismatch &error
  make-output-hash-mismatch output-hash-mismatch?
  (output-path output-hash-mismatch-output-path))

(define (check-fixed-output! output actual-path)
  "Authenticate ACTUAL-PATH against fixed OUTPUT's declared hash."
  (define recursive? (guix-drv:derivation-output-recursive? output))
  (define output-path (guix-drv:derivation-output-path output))
  (define algorithm (guix-drv:derivation-output-hash-algo output))
  (define expected-hash (guix-drv:derivation-output-hash output))

  (unless recursive?
    (let* ((info (lstat actual-path))
           (regular-file? (eq? 'regular (stat:type info)))
           (owner-executable? (not (zero? (logand (stat:perms info) #o100)))))
      (when (or (not regular-file?) owner-executable?)
        (raise-exception (make-flat-output-type-error output-path)))))

  (define actual-hash
    (file-hash* actual-path #:algorithm (lookup-hash-algorithm algorithm)
                #:recursive? recursive? #:select? (const #t)))

  (unless (bytevector=? expected-hash actual-hash)
    (raise-exception (make-output-hash-mismatch output-path))))

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

(define (preserve-failed-output! output-path actual-path)
  "Move ACTUAL-PATH to OUTPUT-PATH after stripping unsafe permission bits.
Do nothing if ACTUAL-PATH is absent; preserve mtimes and remaining permissions."
  (when (false-if-file-not-found (lstat actual-path))
    (secure-file-permissions! actual-path)
    (rename-file actual-path output-path)))

(define (prepare-sandboxed-output! drv-path output-path candidates actual-path)
  "Canonicalize ACTUAL-PATH from DRV-PATH, move it to OUTPUT-PATH, and scan it
using CANDIDATES; return references, NAR SHA-256 and size.
The caller holds OUTPUT-PATH's lock, excludes GC, and prevents concurrent writes
to ACTUAL-PATH's tree.  OUTPUT-PATH is absent; the staged output belongs to the
caller.  Failure after the move leaves the output at OUTPUT-PATH."
  (canonicalize-output! drv-path output-path actual-path)

  ;; Like nixd, temporarily allow moving a canonicalized directory to its new parent.
  (define info (lstat actual-path))
  (define directory? (eq? 'directory (stat:type info)))
  (when directory? (chmod actual-path (logior (stat:perms info) #o700)))
  (rename-file actual-path output-path)
  (when directory? (chmod output-path (stat:perms info)))

  (scan-nar output-path candidates))
