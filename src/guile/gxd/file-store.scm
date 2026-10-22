;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd file-store)
  #:use-module (gxd prelude)
  #:use-module ((gxd database) #:prefix database:
                #:select (valid-path? register-item!))
  #:use-module ((gxd path-locks) #:select (call-with-destination-lock))
  #:use-module ((gxd store-files) #:select (delete-path!))
  #:use-module ((gxd store-path) #:select (fixed-output-path))
  #:use-module ((guix serialization) #:select (restore-file))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((rnrs io ports) #:select (open-bytevector-input-port))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (add-recursive!))

(define (add-recursive! db store-directory name hash hash-algo nar)
  "Restore buffered NAR as a recursive fixed-output item named NAME.
HASH is NAR's digest according to HASH-ALGO.  Return its store path.  NAR must
contain one valid normalized NAR.  An already-valid destination is left
unchanged.  The caller excludes concurrent GC."
  (let ((destination
         (fixed-output-path store-directory name hash
                            #:hash-algo hash-algo #:recursive? #t)))
    (unless (database:valid-path? db destination)
      (call-with-destination-lock destination
        (lambda ()
          ;; Recheck the db one more time in case another daemon session was
          ;; doing the same import while this one was waiting for the
          ;; destination lock
          (unless (database:valid-path? db destination)
            (delete-path! destination)
            (let ((port (open-bytevector-input-port nar)))
              (call-with-cleanup
               (lambda () (close-port port))
               (lambda () (restore-file port destination))))
            (let-values (((nar-hash nar-size) (nar-sha256 destination)))
              (database:register-item!
               db store-directory destination nar-hash nar-size '()))))))
    destination))
