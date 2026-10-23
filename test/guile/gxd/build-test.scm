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
    (observe-bytes!)))
