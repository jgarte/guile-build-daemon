;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd http-server) #:select (call-with-http-server))
  #:use-module ((gxd direct-steps) #:select (direct-steps-fixture))
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture))
  #:use-module ((gxd testbox-relay)
                #:select (client-trust-fixture paired-relay-observers-fixture))
  #:use-module ((gxd testbox snapshots) #:select (paired-snapshots-fixture))
  #:use-module ((gxd testbox database-observations) #:select (database-observations-fixture))
  #:use-module ((guix store) #:select (direct-store-path))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module ((rnrs bytevectors) #:select (string->utf8 u8-list->bytevector bytevector=?))
  #:use-module ((rnrs io ports) #:select (get-bytevector-all))
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

  (test "download binary contents with the builtin builder and register the output" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-snapshot! (get ctx 'observe-snapshot!))
    (define observe-bytes! (get ctx 'observe-bytes!))

    ;; Include NUL and invalid UTF-8 to catch accidental text handling.
    (define contents (u8-list->bytevector '(0 255 128)))
    (define (handler request body)
      (values '((content-type . (application/octet-stream))) contents))

    (define output-path
      (call-with-http-server
       handler
       (lambda (url)
         (define drv
           (step! `(derivation "builtin-download" "builtin:download" ()
                               #:env-vars (("url" . ,(object->string url)))
                               #:hash-algo sha256 #:hash ,(sha256 contents)
                               #:recursive? #f #:substitutable? #f #:local-build? #t)
                  #:connection 'build))

         (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
                #:connection 'build)
         (step! `(build-things (,(guix-drv:derivation-file-name drv)))
                #:connection 'build #:terminal? #t)
         (guix-drv:derivation->output-path drv))))

    (is (observe-db-path! output-path))

    (define published-contents
      (observe-snapshot!
       (lambda (snapshot-directory)
         (call-with-input-file (string-append snapshot-directory output-path)
           get-bytevector-all))))

    (is (bytevector=? contents published-contents))
    (observe-bytes!))

  (test "realize and register matching fixed-output contents" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-snapshot! (get ctx 'observe-snapshot!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))
    (define contents "authenticated contents")
    (define builder-expression
      `(call-with-output-file (getenv "out")
         (lambda (port) (display ,contents port))))

    (define drv
      (step! `(derivation "fixed-output" ,guile
                          ("--no-auto-compile" "-c" ,(object->string builder-expression))
                          #:sources (,guile-store-path)
                          #:hash-algo sha256 #:hash ,(sha256 (string->utf8 contents))
                          #:recursive? #f #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define output-path (guix-drv:derivation->output-path drv))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)
    (is (step! `(build-things (,(guix-drv:derivation-file-name drv)))
               #:connection 'build #:terminal? #t))
    (is (observe-db-path! output-path))

    (define published-contents
      (observe-snapshot!
       (lambda (snapshot-directory)
         (slurp (string-append snapshot-directory output-path)))))

    (is (equal? contents published-contents))
    (observe-bytes!))

  (test "a failing fixed-output builder reports status 1 without registration and keeps the connection usable" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))
    (define contents "otherwise acceptable output")
    (define builder-expression
      `(begin
         (umask #o022)
         (call-with-output-file (getenv "out")
           (lambda (port) (display ,contents port)))
         (exit 7)))

    (define drv
      (step! `(derivation "fixed-output-builder-failure" ,guile
                          ("--no-auto-compile" "-c" ,(object->string builder-expression))
                          #:sources (,guile-store-path)
                          #:hash-algo sha256 #:hash ,(sha256 (string->utf8 contents))
                          #:recursive? #f #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define drv-path (guix-drv:derivation-file-name drv))
    (define output-path (guix-drv:derivation->output-path drv))
    (define expected-error
      `((error/type . store-protocol-error)
        (error/message . ,(string-append "build of `" drv-path "' failed"))
        (error/status . 1)))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)
    (is (equal? expected-error (step! `(build-things (,drv-path)) #:connection 'build)))
    (is (not (observe-db-path! output-path)))
    (is (step! `(valid-path? ,guile-store-path) #:connection 'build #:terminal? #t)
        "connection remained usable")
    (observe-bytes!))

  (test "reject mismatching fixed-output contents without registration and keep the connection usable" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))
    (define builder-expression
      '(call-with-output-file (getenv "out")
         (lambda (port) (display "mismatching contents" port))))

    (define drv
      (step! `(derivation "fixed-output-mismatch" ,guile
                          ("--no-auto-compile" "-c" ,(object->string builder-expression))
                          #:sources (,guile-store-path)
                          #:hash-algo sha256 #:hash ,(sha256 (string->utf8 "expected contents"))
                          #:recursive? #f #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define drv-path (guix-drv:derivation-file-name drv))
    (define output-path (guix-drv:derivation->output-path drv))
    (define expected-error
      `((error/type . store-protocol-error)
        (error/message . ,(string-append "build of `" drv-path "' failed"))
        (error/status . 1)))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)
    (is (equal? expected-error (step! `(build-things (,drv-path)) #:connection 'build)))
    (is (not (observe-db-path! output-path)))
    (is (step! `(valid-path? ,guile-store-path) #:connection 'build #:terminal? #t)
        "connection remained usable")
    (observe-bytes!))

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

  (test "builders see declared read-only inputs and a private writable workspace, but not an undeclared store item" (ctx)
    (define step! (get ctx 'step!))
    (define observe-snapshot! (get ctx 'observe-snapshot!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))
    (define input-path
      (step! '(add-text-to-store "sandbox-input" "declared input") #:connection 'build))

    (define canary-path
      (step! '(add-text-to-store "sandbox-canary" "undeclared canary") #:connection 'build))

    (is (equal? "undeclared canary"
                (observe-snapshot!
                 (lambda (snapshot-directory)
                   (slurp (string-append snapshot-directory canary-path))))))

    (define builder-expression
      '(begin
         (use-modules (ice-9 exceptions) (ice-9 textual-ports))
         (define input-path (getenv "input-path"))
         (define input-contents (call-with-input-file input-path get-string-all))
         (define input-read-only?
           (with-exception-handler
             (lambda (_) #t)
             (lambda ()
               (chmod input-path #o644)
               (call-with-output-file input-path (lambda (port) (display "changed" port)))
               #f)
             #:unwind? #t))

         (call-with-output-file "workspace-file"
           (lambda (port) (display "workspace contents" port)))
         (define workspace-contents (call-with-input-file "workspace-file" get-string-all))
         (call-with-output-file (getenv "out")
           (lambda (port)
             (write `((pid . ,(getpid))
                      (uid . ,(getuid))
                      (gid . ,(getgid))
                      (hostname . ,(gethostname))
                      (input-contents . ,input-contents)
                      (input-read-only? . ,input-read-only?)
                      (undeclared-input-hidden? . ,(not (file-exists? (getenv "canary-path"))))
                      (workspace-writable? . ,(string=? "workspace contents" workspace-contents))
                      (temporary-directory-is-working-directory?
                       . ,(string=? (getcwd) (getenv "TMPDIR"))))
                    port)))))

    (define builder
      (step! `(add-text-to-store "sandbox-builder.scm" ,(object->string builder-expression))
             #:connection 'build))

    (define drv
      (step! `(derivation "sandbox-environment" ,guile ("--no-auto-compile" ,builder)
                          #:sources (,builder ,guile-store-path ,input-path)
                          #:env-vars (("input-path" . ,input-path) ("canary-path" . ,canary-path))
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define output-path (guix-drv:derivation->output-path drv))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)

    (is (step! `(build-things (,(guix-drv:derivation-file-name drv)))
               #:connection 'build #:terminal? #t))

    (define facts
      (observe-snapshot!
       (lambda (snapshot-directory)
         (call-with-input-file (string-append snapshot-directory output-path) read))))

    (define expected-facts
      '((pid . 1)
        (uid . 30001)
        (gid . 30000)
        (hostname . "localhost")
        (input-contents . "declared input")
        (input-read-only? . #t)
        (undeclared-input-hidden? . #t)
        (workspace-writable? . #t)
        (temporary-directory-is-working-directory? . #t)))

    (is (equal? expected-facts facts))

    (observe-bytes!))

  (test "builders have working standard devices and descriptor links, but cannot write to the filesystem root" (ctx)
    (define step! (get ctx 'step!))
    (define observe-snapshot! (get ctx 'observe-snapshot!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))
    (define builder-expression
      '(begin
         (use-modules (ice-9 exceptions) (rnrs bytevectors) (rnrs io ports))

         (define null-port (open-file "/dev/null" "r+"))
         (put-u8 null-port 42)
         (force-output null-port)
         (define dev-null-discards-writes? (eof-object? (get-u8 null-port)))
         (close-port null-port)

         (define zero-bytes
           (call-with-input-file "/dev/zero" (lambda (port) (get-bytevector-n port 8))))

         (define root-write-rejected?
           (with-exception-handler
             (lambda (exception)
               (if (and (eq? 'system-error (exception-kind exception))
                        (= EACCES (system-error-errno
                                   (cons (exception-kind exception) (exception-args exception)))))
                   #t
                   (raise-exception exception)))
             (lambda ()
               (call-with-output-file "/sandbox-write-probe" (lambda (port) (display "write" port)))
               #f)
             #:unwind? #t))

         (call-with-output-file (getenv "out")
           (lambda (port)
             (write `((dev-null-discards-writes? . ,dev-null-discards-writes?)
                      (dev-zero-returns-zero-bytes? . ,(equal? (make-bytevector 8 0) zero-bytes))
                      (descriptor-links
                       . ,(map (lambda (name) (cons name (readlink (string-append "/dev/" name))))
                               '("fd" "stdin" "stdout" "stderr")))
                      (root-write-rejected? . ,root-write-rejected?))
                    port)))))

    (define builder
      (step! `(add-text-to-store "sandbox-devices-builder.scm" ,(object->string builder-expression))
             #:connection 'build))

    (define drv
      (step! `(derivation "sandbox-devices" ,guile ("--no-auto-compile" ,builder)
                          #:sources (,builder ,guile-store-path)
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)

    (is (step! `(build-things (,(guix-drv:derivation-file-name drv)))
               #:connection 'build #:terminal? #t))

    (define facts
      (observe-snapshot!
       (lambda (snapshot-directory)
         (call-with-input-file
             (string-append snapshot-directory (guix-drv:derivation->output-path drv)) read))))

    (define expected-facts
      '((dev-null-discards-writes? . #t)
        (dev-zero-returns-zero-bytes? . #t)
        (descriptor-links . (("fd" . "/proc/self/fd")
                             ("stdin" . "/proc/self/fd/0")
                             ("stdout" . "/proc/self/fd/1")
                             ("stderr" . "/proc/self/fd/2")))
        (root-write-rejected? . #t)))

    (is (equal? expected-facts facts))

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

  (test "a successful builder's FIFO output is rejected and the connection stays usable" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-bytes! (get ctx 'observe-bytes!))
    (define guile (canonicalize-path (require-program "guile")))
    (define guile-store-path (direct-store-path guile))
    (define builder-expression
      '(begin
         (use-modules (system foreign))
         (define make-fifo
           (pointer->procedure int (dynamic-func "mkfifo" (dynamic-link)) (list '* unsigned-int)))

         (unless (zero? (make-fifo (string->pointer (getenv "out")) #o644))
           (error "could not create FIFO output"))))

    (define drv
      (step! `(derivation "fifo-output" ,guile
                          ("--no-auto-compile" "-c" ,(object->string builder-expression))
                          #:sources (,guile-store-path)
                          #:substitutable? #f #:local-build? #t)
             #:connection 'build))

    (define output-path (guix-drv:derivation->output-path drv))
    (define staged-output-path
      (string-append (guix-drv:derivation-file-name drv) ".chroot/top" output-path))

    (define expected-error
      `((error/type . store-protocol-error)
        (error/message . ,(string-append "file `" staged-output-path "' has an unsupported type"))
        (error/status . 1)))

    (step! '(set-build-options #:use-substitutes? #f #:offload? #f #:max-build-jobs 1)
           #:connection 'build)

    (is (equal? expected-error
                (step! `(build-things (,(guix-drv:derivation-file-name drv))) #:connection 'build)))

    (is (eq? #f (observe-db-path! output-path)))
    (is (step! `(valid-path? ,guile-store-path) #:connection 'build #:terminal? #t)
        "connection remained usable")

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
