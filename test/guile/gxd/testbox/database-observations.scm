;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox database-observations)
  #:use-module (gxd test-prelude)
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((sqlite3)
                #:select (SQLITE_OPEN_READONLY sqlite-open sqlite-close
                                               sqlite-prepare sqlite-bind-arguments sqlite-map
                                               sqlite-finalize))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates filter-map))
  #:export (read-store-entries))

(define (query db sql path)
  (let ((statement (sqlite-prepare db sql)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (sqlite-bind-arguments statement path)
        (sqlite-map identity statement))
      (lambda () (sqlite-finalize statement)))))

(define (read-references db path)
  "Return PATH's direct references in DB, sorted by path."
  (map (lambda (row) (vector-ref row 0))
       (query db
              "SELECT target.path FROM Refs
JOIN ValidPaths source ON source.id = Refs.referrer
JOIN ValidPaths target ON target.id = Refs.reference
WHERE source.path = ? ORDER BY target.path;"
              path)))

(define (read-entry db path)
  (match (query db "SELECT hash, narSize, deriver FROM ValidPaths WHERE path = ?;" path)
    (() #f)
    ((#(hash size deriver))
     (cons path
           `((nar-hash . ,hash)
             (nar-size . ,size)
             (deriver . ,deriver)
             (references . ,(read-references db path)))))))

(define (read-store-entries database-file paths)
  "Return DB registration facts for PATHS from read-only DATABASE-FILE.
Entries are keyed by path, unique and sorted; unregistered paths are omitted.
Values contain nar-hash, nar-size, deriver (#f if absent), and direct references."
  (let ((db (sqlite-open database-file SQLITE_OPEN_READONLY)))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (chain paths
          (delete-duplicates _ string=?)
          (sort _ string<?)
          (filter-map (lambda (path) (read-entry db path)) _)))
      (lambda () (sqlite-close db)))))
