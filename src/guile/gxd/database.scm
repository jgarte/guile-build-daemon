;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd database)
  #:use-module ((guix store database) #:select (valid-path-id))
  #:use-module ((sqlite3) #:select (SQLITE_OPEN_READWRITE
                                    sqlite-close sqlite-exec sqlite-open))
  #:export (call-with-database valid-path?))

(define (call-with-database file proc)
  "Call PROC with an open existing database FILE, closing it on return or error."
  (let ((db (sqlite-open file SQLITE_OPEN_READWRITE)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        ;; Match nixd's one-hour lock wait in LocalStore::openDB.
        (sqlite-exec db "PRAGMA busy_timeout = 3600000;")
        (proc db))
      (lambda () (sqlite-close db)))))

(define (valid-path? db path)
  "Return whether PATH is registered in DB."
  (and (valid-path-id db path) #t))
