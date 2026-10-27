;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd direct-steps) #:select (direct-steps-fixture))
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture))
  #:use-module ((gxd testbox-relay)
                #:select (client-trust-fixture paired-relay-observers-fixture))
  #:use-module ((gxd testbox snapshots) #:select (paired-snapshots-fixture))
  #:use-module ((gxd testbox database-observations) #:select (database-observations-fixture))
  #:use-module ((guix store) #:select (direct-store-path))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((ice-9 match) #:select (match-lambda))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (derivation-input derivation-file-name derivation->output-path
                                           derivation->output-paths))
  #:use-module ((ares suitbl core) #:select (define-suite test is)))

(define build-test-fixtures
  (list (client-trust-fixture #t)
        (paired-daemon-testboxes-fixture 'rootless 'nixd 'gxd)
        paired-relay-observers-fixture
        direct-steps-fixture
        paired-snapshots-fixture
        database-observations-fixture))

(define-suite (server-build-tests)
  'metadata `((test/fixtures . ,build-test-fixtures))

  (test "realize a consumer and its dependency, registering their declared outputs" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db! (get ctx 'observe-db!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-snapshot! (get ctx 'observe-snapshot!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))

    (define dependency-expression
      '(begin
         (call-with-output-file (getenv "dev")
           (lambda (port) (display "development\n" port)))
         (call-with-output-file (getenv "out")
           (lambda (port) (display "runtime\n" port)))))

    (define dependency-builder
      (step! `(add-text-to-store "dependency-builder.scm" ,(object->string dependency-expression))
             #:connection 'build))

    (define dependency
      (step! `(derivation "dependency" ,guile ("--no-auto-compile" ,dependency-builder)
                          #:outputs ("dev" "out")
                          #:sources (,dependency-builder ,guile-store-path)
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define dependency-dev-path (guix-drv:derivation->output-path dependency "dev"))
    (define consumer-expression
      '(begin
         (use-modules (ice-9 textual-ports))
         (define contents (call-with-input-file (getenv "dependency-dev-path") get-string-all))
         (call-with-output-file (getenv "out")
           (lambda (port)
             (display contents port)
             (display (getenv "dependency-dev-path") port)))))

    (define consumer-builder
      (step! `(add-text-to-store "consumer-builder.scm" ,(object->string consumer-expression))
             #:connection 'build))

    (define consumer
      (step! `(derivation "consumer" ,guile ("--no-auto-compile" ,consumer-builder)
                          #:inputs (,(guix-drv:derivation-input dependency '("dev")))
                          #:sources (,consumer-builder ,guile-store-path)
                          #:env-vars (("dependency-dev-path" . ,dependency-dev-path))
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define dependency-path (guix-drv:derivation-file-name dependency))
    (define consumer-path (guix-drv:derivation-file-name consumer))
    (define drv-paths (list dependency-path consumer-path))

    (define before (observe-db! drv-paths))

    (is (equal? '() (get-in before `(,dependency-path valid-outputs))))
    (is (equal? '() (get-in before `(,consumer-path valid-outputs))))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)

    (is (step! `(build-things (,consumer-path)) #:connection 'build #:terminal? #t))

    (define after (observe-db! drv-paths))

    (is (equal? (guix-drv:derivation->output-paths dependency)
                (get-in after `(,dependency-path valid-outputs))))
    (is (equal? (guix-drv:derivation->output-paths consumer)
                (get-in after `(,consumer-path valid-outputs))))

    (define consumer-output
      (observe-db-path! (guix-drv:derivation->output-path consumer)))

    (is (equal? (list dependency-dev-path) (get consumer-output 'references)))

    (define output-paths
      (append (map cdr (guix-drv:derivation->output-paths dependency))
              (map cdr (guix-drv:derivation->output-paths consumer))))

    (define registrations (observe-db! output-paths))

    (define filesystem-nars
      (observe-snapshot!
       (lambda (snapshot-directory)
         (chain output-paths
           (sort _ string<?)
           (map (lambda (path)
                  (let-values (((hash nar-size)
                                (nar-sha256 (string-append snapshot-directory path))))
                    (cons path `((nar-hash . ,(string-append "sha256:" (bytevector->base16-string hash)))
                                 (nar-size . ,nar-size)))))
                _)))))

    (is (equal? (map (match-lambda
                       ((path . facts) (cons path (select-keys facts '(nar-hash nar-size)))))
                     registrations)
                filesystem-nars))

    ;; Build logs differ; consume completed captures without comparing their bytes.
    (observe-bytes!))

  (test "when a dependency build fails, the error names the requested consumer and the connection stays usable" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db! (get ctx 'observe-db!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))

    (define dependency-expression
      '(begin
         (umask #o022)
         ;; Both outputs would be acceptable if the builder exited successfully.
         (call-with-output-file (getenv "dev")
           (lambda (port) (display "development\n" port)))
         (call-with-output-file (getenv "out")
           (lambda (port) (display "runtime\n" port)))
         (exit 7)))

    (define dependency-builder
      (step! `(add-text-to-store "failing-dependency-builder.scm"
                                 ,(object->string dependency-expression))
             #:connection 'build))

    (define dependency
      (step! `(derivation "failing-dependency" ,guile ("--no-auto-compile" ,dependency-builder)
                          #:outputs ("dev" "out")
                          #:sources (,dependency-builder ,guile-store-path)
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define consumer-expression
      '(call-with-output-file (getenv "out")
         (lambda (port) (display "consumer\n" port))))

    (define consumer
      (step! `(derivation "consumer-of-failure" ,guile
                          ("--no-auto-compile" "-c" ,(object->string consumer-expression))
                          #:inputs (,(guix-drv:derivation-input dependency '("dev")))
                          #:sources (,guile-store-path)
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define dependency-path (guix-drv:derivation-file-name dependency))
    (define consumer-path (guix-drv:derivation-file-name consumer))
    (define expected-error
      `((error/type . store-protocol-error)
        (error/message . ,(string-append "build of `" consumer-path "' failed"))
        (error/status . 100)))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)

    (is (equal? expected-error
                (step! `(build-things (,consumer-path)) #:connection 'build)))

    (define registrations (observe-db! (list dependency-path consumer-path)))

    (is (equal? '() (get-in registrations `(,dependency-path valid-outputs))))
    (is (equal? '() (get-in registrations `(,consumer-path valid-outputs))))

    (is (step! `(valid-path? ,guile-store-path) #:connection 'build #:terminal? #t))

    (observe-bytes!))

  (test "a missing requested derivation is rejected and the connection stays usable" (ctx)
    (define step! (get ctx 'step!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile-store-path (direct-store-path (canonicalize-path (require-program "guile"))))
    (define drv-path "/gnu/store/00000000000000000000000000000000-missing.drv")
    (define expected-error
      `((error/type . store-protocol-error)
        (error/message . ,(string-append "build of `" drv-path "' failed"))
        (error/status . 1)))

    (is (eq? #f (step! `(valid-path? ,drv-path) #:connection 'build)))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)

    (is (equal? expected-error (step! `(build-things (,drv-path)) #:connection 'build)))
    (is (step! `(valid-path? ,guile-store-path) #:connection 'build #:terminal? #t)
        "connection remained usable")

    (observe-bytes!))

  (test "a builder that exits successfully without its output is rejected and the connection stays usable" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))

    (define drv
      (step! `(derivation "missing-output" ,guile
                          ("--no-auto-compile" "-c" "(exit 0)")
                          #:sources (,guile-store-path)
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define drv-path (guix-drv:derivation-file-name drv))
    (define expected-error
      `((error/type . store-protocol-error)
        (error/message . ,(string-append "build of `" drv-path "' failed"))
        (error/status . 1)))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)

    (is (equal? expected-error
                (step! `(build-things (,drv-path)) #:connection 'build))
        "missing output rejected")

    (define registration (observe-db-path! drv-path))

    (is (equal? '() (get registration 'valid-outputs)))

    (is (step! `(valid-path? ,guile-store-path) #:connection 'build #:terminal? #t)
        "connection remained usable")

    (observe-bytes!)))
