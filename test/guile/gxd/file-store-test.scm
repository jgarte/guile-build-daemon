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
  #:use-module ((gxd file-store) #:select (add-nar-to-store))
  #:use-module ((gxd store-path) #:select (fixed-output-path))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:use-module ((rnrs io ports)
                #:select (get-u8 open-bytevector-input-port
                                 open-bytevector-output-port put-bytevector put-u8))
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
              (destination (add-nar-to-store
                            db dir "item" #t "sha256"
                            (open-bytevector-input-port nar))))
         (is (equal? expected destination))
         (is (database:valid-path? db destination))
         (is (file-exists? destination))
         ;; read-only r--r--r--
         (is (= #o444 (stat:perms (stat destination))))
         (is (equal? destination
                     (add-nar-to-store
                      db dir "item" #t "sha256"
                      (open-bytevector-input-port nar))))))))

  (test "recursive port import consumes exactly one NAR" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (let ((source (string-append dir "/source")))
         (spit source "contents")
         (let-values (((output extract) (open-bytevector-output-port)))
           ;; The byte after the NAR models the next protocol input.
           (put-bytevector output (nar-bytes source))
           (put-u8 output 42)
           (let* ((input (open-bytevector-input-port (extract)))
                  (destination (add-nar-to-store
                                db dir "item" #t "sha256" input)))
             (is (database:valid-path? db destination))
             (is (= 42 (get-u8 input)))))))))

  (test "flat port import stores regular-file contents" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (let ((source (string-append dir "/source")))
         (spit source "contents")
         (let-values (((output extract) (open-bytevector-output-port)))
           (put-bytevector output (nar-bytes source))
           (let* ((input (open-bytevector-input-port (extract)))
                  (destination (add-nar-to-store
                                db dir "item" #f "sha256" input))
                  (expected (fixed-output-path
                             dir "item" (sha256 (string->utf8 "contents"))
                             #:recursive? #f)))
             (is (equal? expected destination))
             (is (database:valid-path? db destination))
             (is (= #o444 (stat:perms (stat destination)))))))))))

