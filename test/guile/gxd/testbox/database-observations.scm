;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox database-observations)
  #:use-module (gxd test-prelude)
  #:use-module ((guix config) #:select (%store-database-directory))
  #:use-module ((ice-9 match) #:select (match match-let match-lambda))
  #:use-module ((sqlite3)
                #:select (SQLITE_OPEN_READONLY sqlite-open sqlite-close
                                               sqlite-prepare sqlite-bind-arguments sqlite-map
                                               sqlite-finalize))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates filter-map))
  #:export (read-store-entries database-observations-fixture))

(define (query db sql path)
  (let ((statement (sqlite-prepare db sql)))
    (call-with-cleanup
     (lambda () (sqlite-finalize statement))
     (lambda ()
       (sqlite-bind-arguments statement path)
       (sqlite-map identity statement)))))

(define (read-references db path)
  "Return PATH's direct references in DB, sorted by path."
  (map (lambda (row) (vector-ref row 0))
       (query db
              "SELECT target.path FROM Refs
JOIN ValidPaths source ON source.id = Refs.referrer
JOIN ValidPaths target ON target.id = Refs.reference
WHERE source.path = ? ORDER BY target.path;"
              path)))

(define (read-outputs db path)
  "Return PATH's declared output name/path pairs in DB, sorted by output name."
  (map (match-lambda (#(name output-path) (cons name output-path)))
       (query db
              "SELECT outputs.id, outputs.path FROM DerivationOutputs outputs
JOIN ValidPaths drv ON drv.id = outputs.drv
WHERE drv.path = ? ORDER BY outputs.id;"
              path)))

(define (read-entry db path)
  (match (query db "SELECT hash, narSize, deriver FROM ValidPaths WHERE path = ?;" path)
    (() #f)
    ((#(hash size deriver))
     (cons path
           `((nar-hash . ,hash)
             (nar-size . ,size)
             (deriver . ,deriver)
             (references . ,(read-references db path))
             (outputs . ,(read-outputs db path)))))))

(define (read-store-entries database-file paths)
  "Return DB registration facts for PATHS from read-only DATABASE-FILE.
Entries are keyed by path, unique and sorted; unregistered paths are omitted.
Values contain nar-hash, nar-size, deriver (#f if absent), direct references,
and declared outputs as sorted name/path pairs (empty for ordinary files)."
  (let ((db (sqlite-open database-file SQLITE_OPEN_READONLY)))
    (call-with-cleanup
     (lambda () (sqlite-close db))
     (lambda ()
       (chain paths
         (delete-duplicates _ string=?)
         (sort _ string<?)
         (filter-map (lambda (path) (read-entry db path)) _))))))

(define (database-observations-fixture ctx proceed)
  "Add `observe-db!' and `observe-db-path!' to CTX using the snapshot fixture.
The plural operation returns path-keyed registration facts for a path list;
the singular operation returns one path's facts, or #f if unregistered.
Both raise on differences between the paired databases."
  (let ((snapshot! (get ctx 'snapshot!)))
    (unless snapshot!
      (error "database observations require the snapshot fixture"))

    (define (observe-db! paths)
      (match-let (((left-root right-root) (snapshot!)))
        (let* ((suffix (string-append %store-database-directory "/db.sqlite"))
               (left (read-store-entries (string-append left-root suffix) paths))
               (right (read-store-entries (string-append right-root suffix) paths)))
          (unless (equal? left right)
            (error "store database entries differ" left right))
          left)))

    (define (observe-db-path! path)
      "Return common registration facts for PATH, or #f if unregistered."
      (assoc-ref (observe-db! (list path)) path))

    (proceed (append `((observe-db! . ,observe-db!)
                       (observe-db-path! . ,observe-db-path!))
                     ctx)
             (lambda () #t))))
