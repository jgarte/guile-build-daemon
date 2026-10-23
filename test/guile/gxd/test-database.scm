;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd test-database)
  #:use-module (gxd test-prelude)
  #:use-module ((sqlite3)
                #:select (sqlite-prepare sqlite-bind-arguments sqlite-map sqlite-finalize))
  #:export (query))

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
