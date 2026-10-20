;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd database)
  #:use-module (gxd prelude)
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((guix store database)
                #:prefix guix-db:
                #:select (register-valid-path valid-path-id))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception with-exception-handler))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((srfi srfi-19) #:select (current-time time-utc))
  #:use-module ((sqlite3) #:select (SQLITE_OPEN_READWRITE
                                    sqlite-close sqlite-exec sqlite-open))
  #:export (call-with-database valid-path? register-text!
                               &invalid-reference invalid-reference?
                               invalid-reference-message))

(define-exception-type &invalid-reference &error
  make-invalid-reference invalid-reference?
  (message invalid-reference-message))

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
      (sqlite-exec db "ROLLBACK;")
      (raise-exception exception))
    (lambda ()
      (thunk)
      (sqlite-exec db "COMMIT;"))
    #:unwind? #t))

(define (register-text! db path hash size references)
  "Register fresh non-derivation PATH and REFERENCES atomically in DB.
HASH and SIZE describe PATH's NAR.  REFERENCES must be sorted unique store paths.
Raise an invalid-reference error if a reference is not registered valid.
The caller owns PATH's destination lock and has materialized its contents."
  (call-with-transaction db
    (lambda ()
      (for-each
       (lambda (reference)
         (unless (valid-path? db reference)
           (raise-exception
            (make-invalid-reference
             (format #f "path `~a' is not valid" reference)))))
       references)
      (guix-db:register-valid-path
       db #:path path #:references references #:deriver #f
       #:hash (string-append "sha256:" (bytevector->base16-string hash))
       #:nar-size size
       ;; Guix's default honors SOURCE_DATE_EPOCH; daemon registration uses now.
       #:time (current-time time-utc)))))
