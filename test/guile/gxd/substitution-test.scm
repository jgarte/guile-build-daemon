;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd substitution-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd substitute-cache) #:select (call-with-substitute-cache))
  #:use-module ((gxd direct-steps) #:select (direct-steps-fixture))
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture))
  #:use-module ((gxd testbox-relay)
                #:select (client-trust-fixture paired-relay-observers-fixture))
  #:use-module ((gxd testbox snapshots) #:select (paired-snapshots-fixture))
  #:use-module ((gxd testbox database-observations) #:select (database-observations-fixture))
  #:use-module ((guix derivations) #:prefix guix-drv:
                #:select (derivation-file-name derivation->output-path))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((guix serialization)
                #:select (substitutable-path substitutable-deriver substitutable-references
                          substitutable-download-size substitutable-nar-size))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((rnrs bytevectors) #:select (u8-list->bytevector bytevector=?))
  #:use-module ((rnrs io ports) #:select (get-bytevector-all put-bytevector))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((ares suitbl core) #:select (define-suite test is)))

(define-suite (server-substitution-tests)
  'metadata
  `((test/fixtures
     . ,(list (client-trust-fixture #t)
              (paired-daemon-testboxes-fixture 'rootless 'nixd 'gxd)
              paired-relay-observers-fixture direct-steps-fixture
              paired-snapshots-fixture database-observations-fixture)))

  (test "query signed substitute metadata, omitting an unavailable path without registering the output" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define drv
      (step! '(derivation "substitute-metadata" "/impossible-substitute-builder" ())
             #:connection 'query))

    (define drv-path (guix-drv:derivation-file-name drv))
    (define output-path (guix-drv:derivation->output-path drv))
    (define missing-path (string-append drv-path "-missing"))
    (define (metadata info)
      `((path . ,(substitutable-path info))
        (deriver . ,(substitutable-deriver info))
        (references . ,(substitutable-references info))
        (download-size . ,(substitutable-download-size info))
        (nar-size . ,(substitutable-nar-size info))))

    (define-values (expected-metadata actual-metadata)
      (call-with-temporary-directory
       (lambda (directory)
         (define source-path (string-append directory "/payload"))
         (spit source-path "metadata payload")
         (define expected-metadata
           (let-values (((hash size) (nar-sha256 source-path)))
             `(((path . ,output-path)
                (deriver . ,drv-path)
                (references)
                (download-size . 0)
                (nar-size . ,size)))))

         (call-with-substitute-cache
          drv source-path
          (lambda (url)
            (step! `(set-build-options #:use-substitutes? #t #:substitute-urls (,url))
                   #:connection 'query)
            (values expected-metadata
                    (map metadata
                         (step! `(query-substitutable-path-infos (,output-path ,missing-path))
                                #:connection 'query #:terminal? #t))))))))

    (is (equal? expected-metadata actual-metadata))
    (is (not (observe-db-path! output-path))))

  (test "substitute an authenticated binary output without running its builder" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))
    (define observe-snapshot! (get ctx 'observe-snapshot!))

    (define drv
      (step! '(derivation "authenticated-substitute" "/impossible-substitute-builder" ())
             #:connection 'build))

    (define drv-path (guix-drv:derivation-file-name drv))
    (define output-path (guix-drv:derivation->output-path drv))
    ;; Include NUL and bytes that are not valid UTF-8.
    (define contents (u8-list->bytevector '(0 255 128)))

    (define-values (build-result connection-usable?)
      (call-with-temporary-directory
       (lambda (directory)
         (define source-path (string-append directory "/payload"))
         (call-with-output-file source-path (lambda (port) (put-bytevector port contents)))
         (call-with-substitute-cache
          drv source-path
          (lambda (url)
            (step! `(set-build-options #:use-substitutes? #t #:substitute-urls (,url)
                                       #:offload? #f #:max-build-jobs 1 #:fallback? #f)
                   #:connection 'build)
            (define build-result (step! `(build-things (,drv-path)) #:connection 'build))
            (values build-result
                    (step! `(valid-path? ,output-path) #:connection 'build #:terminal? #t)))))))

    (is (eq? #t build-result))
    (is (eq? #t connection-usable?) "connection remained usable")

    (define registration (observe-db-path! output-path))
    (define published
      (observe-snapshot!
       (lambda (snapshot-directory)
         (define path (string-append snapshot-directory output-path))
         (let-values (((hash size) (nar-sha256 path)))
           (list (call-with-input-file path get-bytevector-all)
                 (string-append "sha256:" (bytevector->base16-string hash)) size)))))

    (match-let (((published-contents nar-hash nar-size) published))
      (is (bytevector=? contents published-contents))
      (is (equal? `((nar-hash . ,nar-hash)
                    (nar-size . ,nar-size)
                    (deriver . ,drv-path)
                    (references))
                  (select-keys registration '(nar-hash nar-size deriver references)))))))
