;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd file-store-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module ((guix serialization) #:select (write-file))
  #:use-module ((guix store database) #:prefix guix-db:
                #:select (call-with-database))
  #:use-module ((gxd database) #:prefix database: #:select (valid-path?))
  #:use-module ((gxd file-store) #:select (add-recursive!))
  #:use-module ((gxd store-path) #:select (fixed-output-path))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((rnrs io ports) #:select (open-bytevector-output-port))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module (gxd test-prelude))

(define (nar-bytes source)
  "Return SOURCE's normalized NAR as a bytevector."
  (let-values (((port extract) (open-bytevector-output-port)))
    (write-file source port)
    (extract)))

(define (call-with-tmp-dir-and-database proc)
  "Call PROC with a temporary directory and a database."
  (call-with-temporary-directory
   (lambda (tmp-dir)
     (define (proc-tmp-dir db) (proc tmp-dir db))
     (let ((database-file (string-append tmp-dir "/db.sqlite")))
       (guix-db:call-with-database database-file proc-tmp-dir)))))

(define-suite (file-store-tests)
  (test "recursive import restores and registers a regular file" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (let* ((source (string-append dir "/source"))
              (content (spit source "contents"))
              (nar (nar-bytes source))
              (hash (sha256 nar))
              (expected (fixed-output-path dir "item" hash))
              (destination (add-recursive! db dir "item" hash 'sha256 nar)))
         (is (equal? expected destination))
         (is (database:valid-path? db destination))
         (is (file-exists? destination))
         ;; read-only r--r--r--
         (is (= #o444 (stat:perms (stat destination))))
         ;; existing item is selected without rereading NAR
         (is (equal? destination
                     (add-recursive! db dir "item" hash 'sha256 #vu8()))))))))

