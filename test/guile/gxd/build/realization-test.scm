;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build realization-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd test-database) #:select (call-with-empty-database))
  #:use-module ((gxd build realization) #:select (realize-derivation!))
  #:use-module ((gxd derivations) #:select (read-derivation))
  #:use-module ((gxd database)
                #:prefix database:
                #:select (valid-path? references))
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (derivation-outputs derivation-output-path derivation-builder
                                             derivation-builder-arguments derivation-builder-environment-vars))
  #:use-module ((srfi srfi-9 gnu) #:select (set-fields))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((ares suitbl checks) #:select (throws-exception?)))

(define (build-derivation dev-path out-path expression)
  "Return a derivation evaluating Guile EXPRESSION with DEV-PATH and OUT-PATH as outputs."
  (let* ((drv (call-with-resource "build-inputs/candidate.drv" read-derivation))
         (outputs (guix-drv:derivation-outputs drv)))
    (set-fields drv
      ((guix-drv:derivation-outputs)
       (list (cons "dev" (set-fields (assoc-ref outputs "dev")
                           ((guix-drv:derivation-output-path) dev-path)))
             (cons "out" (set-fields (assoc-ref outputs "out")
                           ((guix-drv:derivation-output-path) out-path)))))
      ((guix-drv:derivation-builder) (require-program "guile"))
      ((guix-drv:derivation-builder-arguments)
       (list "--no-auto-compile" "-c" (object->string expression)))
      ((guix-drv:derivation-builder-environment-vars)
       `(("dev" . ,dev-path) ("out" . ,out-path))))))

(define (call-with-build-context proc)
  "Call PROC with DB, store directory, two output paths and a realization procedure."
  (call-with-empty-database
   (lambda (db directory)
     (let* ((store-directory (string-append directory "/store"))
            (dev-path (string-append store-directory "/" (make-string 32 #\a) "-example-dev"))
            (out-path (string-append store-directory "/" (make-string 32 #\b) "-example"))
            (drv-path (string-append store-directory "/example.drv")))
       (mkdir store-directory)
       (proc db store-directory dev-path out-path
             (lambda (drv)
               (realize-derivation! db store-directory drv-path drv directory 1 (lambda (_) #t))))))))

(define-suite (realize-tests)
  (test "realize two outputs with self and sibling references; a second realization returns already-valid" ()
    (call-with-build-context
     (lambda (db store-directory dev-path out-path realize!)
       (define drv
         (build-derivation
          dev-path out-path
          '(begin
             (when (or (file-exists? (getenv "dev")) (file-exists? (getenv "out")))
               (error "outputs already exist"))
             (umask #o022)
             (call-with-output-file (getenv "dev")
               (lambda (port)
                 (display (getenv "dev") port)
                 (display (getenv "out") port)))
             (call-with-output-file (getenv "out")
               (lambda (port) (display "leaf" port))))))

       (define result (deadline 5 (realize! drv)))

       (is (eq? 'built result))
       (is (file-exists? dev-path))
       (is (file-exists? out-path))
       (is (database:valid-path? db dev-path))
       (is (database:valid-path? db out-path))
       (is (equal? (list dev-path out-path) (database:references db dev-path)))
       (is (null? (database:references db out-path)))

       (is (eq? 'already-valid (deadline 5 (realize! drv)))))))

  (test "leave outputs unregistered when the builder exits unsuccessfully" ()
    (call-with-build-context
     (lambda (db store-directory dev-path out-path realize!)
       (define drv
         (build-derivation
          dev-path out-path
          '(begin
             (umask #o022)
             (call-with-output-file (getenv "dev")
               (lambda (port) (display "incomplete" port)))
             (call-with-output-file (getenv "out")
               (lambda (port) (display "incomplete" port)))
             (exit 7))))

       (is (throws-exception? (deadline 5 (realize! drv))))
       (is (not (database:valid-path? db dev-path)))
       (is (not (database:valid-path? db out-path)))))))
