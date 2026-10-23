;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd database-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd test-database) #:select (query call-with-empty-database))
  #:use-module ((gxd database)
                #:select (register-outputs! make-output-info valid-path? references
                                            reference-cycle-path invalid-reference-path))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((rnrs bytevectors) #:select (make-bytevector)))

(define (registered-references db)
  "Return every stored reference as a referrer/reference path vector, sorted by paths."
  (query db "SELECT a.path, b.path FROM Refs r
JOIN ValidPaths a ON a.id = r.referrer JOIN ValidPaths b ON b.id = r.reference
ORDER BY a.path, b.path;"))

(define (registration-snapshot db)
  "Return all registration tables and allocation counters in deterministic order."
  (map (lambda (sql) (query db sql))
       '("SELECT * FROM ValidPaths ORDER BY id;"
         "SELECT * FROM Refs ORDER BY referrer, reference;"
         "SELECT * FROM DerivationOutputs ORDER BY drv, id;"
         "SELECT * FROM sqlite_sequence ORDER BY name;")))

(define-suite (database-reference-tests)
  (test "read direct references and distinguish a registered leaf from an absent path" ()
    (call-with-empty-database
     (lambda (db directory)
       (let* ((leaf-path (string-append directory "/leaf"))
              (parent-path (string-append directory "/parent"))
              (missing-path (string-append directory "/missing"))
              (hash (make-bytevector 32 0))
              (nar-size 120)
              (expected-references (list leaf-path parent-path)))

         (register-outputs! db directory "/store/producer.drv"
                            (list (make-output-info parent-path hash nar-size expected-references)
                                  (make-output-info leaf-path hash nar-size '())))

         (is (equal? expected-references (references db parent-path)))
         (is (null? (references db leaf-path)))

         (define failure (capture-exception (lambda () (references db missing-path))))

         (is (equal? missing-path (invalid-reference-path failure))))))))

(define-suite (database-output-tests)
  (test "register a self-reference with the supplied NAR metadata and producing derivation" ()
    (call-with-empty-database
     (lambda (db directory)
       (let* ((path (string-append directory "/self"))
              (drv-path (string-append directory "/producer.drv"))
              (hash (make-bytevector 32 17))
              (nar-size 120)
              (expected-metadata
               (list (vector path (string-append "sha256:" (bytevector->base16-string hash))
                             nar-size drv-path))))

         (register-outputs! db directory drv-path
                            (list (make-output-info path hash nar-size (list path))))

         (is (equal? expected-metadata
                     (query db "SELECT path, hash, narSize, deriver FROM ValidPaths;")))
         (is (equal? (list (vector path path)) (registered-references db)))))))

  (test "register an output referring to a sibling supplied later in the batch" ()
    (call-with-empty-database
     (lambda (db directory)
       (let ((first-path (string-append directory "/first"))
             (second-path (string-append directory "/second"))
             (hash (make-bytevector 32 0))
             (nar-size 120))

         (register-outputs! db directory "/store/producer.drv"
                            (list (make-output-info first-path hash nar-size (list second-path))
                                  (make-output-info second-path hash nar-size '())))

         (is (equal? (list (vector first-path second-path)) (registered-references db)))))))

  (test "reject a sibling-reference cycle and roll back the whole batch" ()
    (call-with-empty-database
     (lambda (db directory)
       (let* ((first-path (string-append directory "/first"))
              (second-path (string-append directory "/second"))
              (hash (make-bytevector 32 0))
              (nar-size 120)
              (before (registration-snapshot db)))

         (define failure
           (capture-exception
            (lambda ()
              (register-outputs!
               db directory "/store/producer.drv"
               (list (make-output-info second-path hash nar-size (list first-path))
                     (make-output-info first-path hash nar-size (list second-path)))))))

         (is (equal? first-path (reference-cycle-path failure)))
         (is (equal? before (registration-snapshot db)))))))

  (test "register a missing dependency and retry the identical rejected output batch" ()
    (call-with-empty-database
     (lambda (db directory)
       (let* ((output-path (string-append directory "/output"))
              (sibling-path (string-append directory "/sibling"))
              (missing-path (string-append directory "/missing"))
              (hash (make-bytevector 32 0))
              (nar-size 120)
              (output-infos (list (make-output-info output-path hash nar-size (list missing-path sibling-path))
                                  (make-output-info sibling-path hash nar-size '())))
              (before (registration-snapshot db)))

         (define failure
           (capture-exception
            (lambda () (register-outputs! db directory "/store/producer.drv" output-infos))))

         (is (equal? missing-path (invalid-reference-path failure)))
         (is (equal? before (registration-snapshot db)))

         (register-outputs! db directory "/store/dependency.drv"
                            (list (make-output-info missing-path hash nar-size '())))
         (register-outputs! db directory "/store/producer.drv" output-infos)

         (is (valid-path? db sibling-path))
         (is (equal? (list (vector output-path missing-path) (vector output-path sibling-path))
                     (registered-references db))))))))
