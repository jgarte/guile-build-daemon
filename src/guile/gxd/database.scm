;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd database)
  #:use-module (gxd prelude)
  #:use-module ((gxd derivations)
                #:prefix derivations:
                #:select (read-derivation resolve-inputs! check-outputs))
  #:use-module ((guix derivations)
                #:select (derivation-outputs derivation-output-path))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((guix store database)
                #:prefix guix-db:
                #:select (register-valid-path valid-path-id))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception with-exception-handler))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((ice-9 match) #:select (match-lambda))
  #:use-module ((srfi srfi-19) #:select (current-time time-utc))
  #:use-module ((sqlite3) #:select (SQLITE_OPEN_READWRITE
                                    sqlite-close sqlite-exec sqlite-open
                                    sqlite-prepare sqlite-bind-arguments sqlite-step sqlite-finalize))
  #:export (call-with-database valid-path? register-item!
                               &invalid-reference invalid-reference?
                               invalid-reference-message invalid-reference-path))

(define-exception-type &invalid-reference &error
  make-invalid-reference invalid-reference?
  (message invalid-reference-message)
  (path invalid-reference-path))

(define (call-with-database file proc)
  "Call PROC with an open existing database FILE, closing it on return or error."
  (let ((db (sqlite-open file SQLITE_OPEN_READWRITE)))
    (call-with-cleanup
     (lambda () (sqlite-close db))
     (lambda ()
       ;; Match nixd's one-hour lock wait in LocalStore::openDB.
       (sqlite-exec db "PRAGMA busy_timeout = 3600000;")
       (proc db)))))

(define (valid-path? db path)
  "Return whether PATH is registered in DB."
  (and (guix-db:valid-path-id db path) #t))

(define (call-with-transaction db thunk)
  "Call THUNK in an immediate transaction on DB; commit on return, roll back on exception."
  (sqlite-exec db "BEGIN IMMEDIATE;")
  (with-exception-handler
    (lambda (exception)
      ;; Resolved inputs may depend on validity rows undone by this transaction.
      (hash-clear! resolved-inputs)
      (false-if-exception (sqlite-exec db "ROLLBACK;"))
      (raise-exception exception))
    (lambda ()
      (thunk)
      (sqlite-exec db "COMMIT;"))
    #:unwind? #t))

(define (check-references db references)
  "Raise an invalid-reference error for the first unregistered path in REFERENCES."
  (for-each
   (lambda (reference)
     (unless (valid-path? db reference)
       (raise-exception
        (make-invalid-reference
         (format #f "path `~a' is not valid" reference) reference))))
   references))

(define (register-path! db path hash size references deriver)
  "Insert or update PATH's NAR metadata and REFERENCES in DB's current transaction."
  (guix-db:register-valid-path
   db #:path path #:references references #:deriver deriver
   #:hash (string-append "sha256:" (bytevector->base16-string hash))
   #:nar-size size
   ;; Guix's default honors SOURCE_DATE_EPOCH; daemon registration uses now.
   #:time (current-time time-utc)))

(define* (register-item! db store-directory path hash size references #:key deriver)
  "Register fresh PATH in STORE-DIRECTORY with HASH, SIZE and REFERENCES in DB.
HASH and SIZE describe its NAR; REFERENCES are sorted unique store paths.
DERIVER names the producing derivation, or is #f when none is supplied.
Validate declared outputs when PATH names a derivation.  The caller has
materialized PATH, holds its destination lock and excludes concurrent GC."
  (if (string-suffix? ".drv" path)
      (register-derivation! db store-directory path hash size references deriver)
      (call-with-transaction db
        (lambda ()
          (check-references db references)
          (register-path! db path hash size references deriver)))))

(define (execute db sql arguments)
  "Run SQL on DB with bound ARGUMENTS; return its first row or #f if none.
Propagate SQLite errors."
  (let ((statement (sqlite-prepare db sql)))
    (call-with-cleanup
     (lambda () (sqlite-finalize statement))
     (lambda ()
       (apply sqlite-bind-arguments statement arguments)
       (sqlite-step statement)))))

;; Cached derivation files must remain valid and unchanged for this process's lifetime.
(define resolved-inputs (make-hash-table))

(define (read-registered-derivation! db path)
  "Return PATH's resolved derivation, reusing cached records for the process lifetime.
On a cache miss, require PATH to be registered in DB and read its file."
  (or (hash-ref resolved-inputs path)
      (begin
        (check-references db (list path))
        (let* ((drv (call-with-input-file path derivations:read-derivation))
               (resolved-drv
                (derivations:resolve-inputs!
                 drv (lambda (input) (read-registered-derivation! db input)))))
          (hash-set! resolved-inputs path resolved-drv)
          resolved-drv))))

(define (record-derivation-outputs! db path)
  "Read derivation PATH and record its declared output mappings in DB.
PATH's validity row must exist in the current transaction.  Return the derivation."
  (define drv (call-with-input-file path derivations:read-derivation))
  (define id (guix-db:valid-path-id db path))

  (for-each
   (match-lambda
     ((name . output)
      (execute db
               "INSERT OR REPLACE INTO DerivationOutputs (drv, id, path) VALUES (?, ?, ?);"
               (list id name (derivation-output-path output)))))
   (derivation-outputs drv))
  drv)

(define (check-derivation-outputs! db store-directory drv-path drv)
  "Resolve DRV's inputs through DB and check its declared output paths.
DRV-PATH is the store path of the derivation file; its name determines the
expected output paths within STORE-DIRECTORY."
  (derivations:check-outputs
   store-directory drv-path
   (derivations:resolve-inputs!
    drv (lambda (input) (read-registered-derivation! db input)))))

(define (register-references! db path references)
  "Validate REFERENCES and add their edges from registered PATH in DB.
Use the caller's transaction; all referenced validity rows must exist."
  (check-references db references)
  (define id (guix-db:valid-path-id db path))

  (for-each
   (lambda (reference)
     (execute db "INSERT OR REPLACE INTO Refs (referrer, reference) VALUES (?, ?);"
              (list id (guix-db:valid-path-id db reference))))
   references))

(define (register-derivation! db store-directory path hash size references deriver)
  "Register fresh derivation PATH and its declared outputs atomically in DB.
HASH and SIZE describe PATH's NAR; REFERENCES are sorted unique store paths.
The caller has materialized PATH and owns its destination lock, excluding GC.
Read canonical Guix derivations; propagate decoding, lookup and output-check errors."
  (call-with-transaction db
    (lambda ()
      (register-path! db path hash size '() deriver)
      (define drv (record-derivation-outputs! db path))
      (register-references! db path references)
      (check-derivation-outputs! db store-directory path drv))))
