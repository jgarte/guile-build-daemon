;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build-inputs-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd test-database) #:select (query call-with-empty-database))
  #:use-module ((gxd build-inputs)
                #:select (reference-candidates missing-input-output-drv-path
                                               missing-input-output-input-path
                                               missing-input-output-name))
  #:use-module ((gxd derivations) #:select (read-derivation))
  #:use-module ((guix store database)
                #:prefix guix-db:
                #:select (register-valid-path))
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (derivation-input derivation-input-derivation
                                           derivation-inputs derivation-sources))
  #:use-module ((srfi srfi-9 gnu) #:select (set-fields))
  #:use-module ((ares suitbl core) #:select (define-suite test is)))

(define (add-output-mapping! db drv-path name path)
  "Add a named output mapping for registered DRV-PATH to the fixture DB."
  (query db "INSERT INTO DerivationOutputs (drv, id, path)
SELECT id, ?, ? FROM ValidPaths WHERE path = ?;"
         name path drv-path))

(define (call-with-input-database proc)
  "Call PROC with registered input outputs and a source sharing a leaf dependency."
  (call-with-empty-database
   (lambda (db _)
     (define (register path references)
       (guix-db:register-valid-path
        db #:path path #:references references
        #:hash (string-append "sha256:" (make-string 64 #\0)) #:nar-size 120))

     (register "/store/leaf" '())
     (register "/store/input-dev" '("/store/leaf"))
     (register "/store/input-out" '())
     (register "/store/source-dependency" '())
     (register "/store/source" '("/store/leaf" "/store/source-dependency"))
     (register "/store/input.drv" '())
     (add-output-mapping! db "/store/input.drv" "dev" "/store/input-dev")
     (add-output-mapping! db "/store/input.drv" "out" "/store/input-out")

     (proc db))))

(define (candidate-derivation output-name)
  "Return a decoded derivation selecting OUTPUT-NAME from the fixture input."
  (let* ((drv (call-with-resource "build-inputs/candidate.drv" read-derivation))
         (input
          (set-fields (guix-drv:derivation-input (empty-derivation) (list output-name))
            ((guix-drv:derivation-input-derivation) "/store/input.drv"))))
    (set-fields drv
      ((guix-drv:derivation-inputs) (list input))
      ((guix-drv:derivation-sources) '("/store/source")))))

(define-suite (build-inputs-tests)
  (test "select dev and the source with their shared dependency, plus both own outputs" ()
    (call-with-input-database
     (lambda (db)
       (let ((drv-path "/store/consumer.drv")
             (drv (candidate-derivation "dev"))
             (expected-candidates '("/store/input-dev" "/store/leaf" "/store/own-dev"
                                    "/store/own-out" "/store/source" "/store/source-dependency")))

         (is (equal? expected-candidates (reference-candidates db drv-path drv)))))))

  (test "reject a requested output absent from the input derivation" ()
    (call-with-input-database
     (lambda (db)
       (let* ((drv-path "/store/consumer.drv")
              (input-drv-path "/store/input.drv")
              (missing-output-name "missing")
              (drv (candidate-derivation missing-output-name)))

         (define failure
           (capture-exception (lambda () (reference-candidates db drv-path drv))))

         (is (equal? drv-path (missing-input-output-drv-path failure)))
         (is (equal? input-drv-path (missing-input-output-input-path failure)))
         (is (equal? missing-output-name (missing-input-output-name failure))))))))
