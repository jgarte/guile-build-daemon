;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd test-database)
  #:use-module (gxd test-prelude)
  #:use-module ((guix store database)
                #:prefix guix-db:
                #:select (call-with-database))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((sqlite3)
                #:select (sqlite-exec sqlite-prepare sqlite-bind-arguments sqlite-map sqlite-finalize))
  #:export (query call-with-empty-database))

(define (call-with-empty-database proc)
  "Call PROC with a temporary full-schema database and its containing directory."
  (call-with-temporary-directory
   (lambda (directory)
     (guix-db:call-with-database
      (string-append directory "/db.sqlite")
      (lambda (db)
        (sqlite-exec db "PRAGMA foreign_keys = ON;")
        (proc db directory))))))

(define (query db sql . arguments)
  "Execute SQL in DB with bound ARGUMENTS, returning its rows as vectors.
Statements without result rows return an empty list.  Finalize the statement
on return or exception; leave DB open."
  (define statement (sqlite-prepare db sql))

  (call-with-cleanup
   (lambda () (sqlite-finalize statement))
   (lambda ()
     (apply sqlite-bind-arguments statement arguments)
     (sqlite-map identity statement))))
