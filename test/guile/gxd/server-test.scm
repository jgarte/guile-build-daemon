;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd server-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix store) #:select (direct-store-path store-connection-socket valid-path?
                                                         output-path))
  #:use-module ((guix derivations)
                #:select (derivation derivation-input derivation-file-name
                                     derivation->output-paths derivation-inputs
                                     derivation-input-path derivation-sources
                                     derivation-outputs derivation-output-path
                                     derivation-output-hash derivation-output-hash-algo
                                     write-derivation read-derivation derivation-hash
                                     derivation-builder-environment-vars))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((ice-9 match) #:select (match-let match-lambda match-lambda*))
  #:use-module ((srfi srfi-1) #:select (append-map alist-delete))
  #:use-module ((rnrs bytevectors) #:select (bytevector=? string->utf8 make-bytevector))
  #:use-module ((rnrs io ports) #:select (lookahead-u8))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((srfi srfi-9 gnu) #:select (set-fields))
  #:use-module ((gxd direct-steps) #:select (call-with-paired-clients paired-step!))
  #:use-module ((gxd store-path) #:select (text-path))
  #:use-module ((gxd test-fixtures) #:select (paired-testbox-fixtures))
  #:use-module (gxd test-prelude)
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture testbox-root))
  #:use-module ((gxd testbox snapshots) #:select (paired-snapshots-fixture))
  #:use-module ((gxd testbox database-observations) #:select (database-observations-fixture))
  #:use-module ((gxd testbox store-observations) #:select (store-observations-fixture))
  #:use-module ((gxd testbox-relay)
                #:select (client-trust-fixture paired-relay-observers-fixture)))

(define (derivation->text drv)
  "Return the serialized derivation for DRV."
  (call-with-output-string
   (lambda (port) (write-derivation drv port))))

(define (test-derivation)
  "Return a completed single-output derivation named example, without store access."
  (let* ((drv (call-with-input-string
                  "Derive([(\"out\",\"\",\"\",\"\")],[],[],\"x86_64-linux\",\"/bin/sh\",[],[(\"out\",\"\")])"
                read-derivation))
         (path (output-path "out" (derivation-hash drv) "example"))
         (output (assoc-ref (derivation-outputs drv) "out")))
    (set-fields drv
      ((derivation-outputs)
       (list (cons "out" (set-fields output ((derivation-output-path) path)))))
      ((derivation-builder-environment-vars) (list (cons "out" path))))))

(define (derivation-text-path name drv)
  "Return the text store path for DRV submitted under NAME."
  (text-path "/gnu/store" name (string->utf8 (derivation->text drv)) '()))

(define (incorrect-output-error drv-path declared-path expected-path)
  "Return the expected protocol error for DRV-PATH's DECLARED-PATH versus EXPECTED-PATH."
  `((error/type . store-protocol-error)
    (error/message . ,(string-append
                       "derivation `" drv-path "' has incorrect output `"
                       declared-path "', should be `" expected-path "'"))
    (error/status . 1)))

(define (derivation-steps-fixture ctx proceed)
  "Add registration-outcome! to CTX using its checked step! and DB observer."
  (define step! (get ctx 'step!))
  (define observe-db! (get ctx 'observe-db!))
  (define present-path
    (direct-store-path (canonicalize-path (require-program "guix-daemon"))))

  (define* (registration-outcome! name drv #:key (terminal? #t))
    "Submit DRV under NAME and observe its registration and subsequent connection usability.
Return response, registration and connection-usable? fields.  Check usability
by querying a known valid store item on the same connections.
With TERMINAL? true, close and capture-check the session after the query;
otherwise retain the same connections for the next submission."
    (let* ((text (derivation->text drv))
           (path (derivation-text-path name drv))
           (outcome (step! `(add-text-to-store ,name ,text) #:connection 'derivation))
           (registration (observe-db! (list path)))
           (usable? (step! `(valid-path? ,present-path)
                           #:connection 'derivation #:terminal? terminal?)))
      `((response . ,outcome)
        (registration . ,registration)
        (connection-usable? . ,usable?))))

  (proceed (acons 'registration-outcome! registration-outcome! ctx) (lambda () #t)))

(define derivation-test-fixtures
  (append (paired-testbox-fixtures 'rootless 'nixd 'gxd)
          (list paired-snapshots-fixture database-observations-fixture
                derivation-steps-fixture)))

(define (remote-eof? store)
  "Return whether STORE reaches remote EOF within five seconds."
  (let ((socket (store-connection-socket store)))
    (and (memq socket (car (select (list socket) '() '() 5)))
         (eof-object? (lookahead-u8 socket)))))

(define-suite (server-text-tests)
  'metadata `((test/fixtures
               . ,(append (paired-testbox-fixtures 'rootless 'nixd 'gxd)
                          (list paired-snapshots-fixture store-observations-fixture
                                database-observations-fixture))))

  (test "text ingress creates matching regular read-only store entries" (ctx)
    (let* ((step! (get ctx 'step!))
           (a (step! '(add-text-to-store "gxd-text-a" "reference\n")
                     #:connection 'a))
           (b (step! `(add-text-to-store "gxd-text-b" "payload\n" (,a))
                     #:connection 'a)))
      (is (chain `(valid-path? ,b)
            (step! _ #:connection 'a #:terminal? #t)
            (eq? #t _)))

      (define inventory ((get ctx 'observe-store!)))
      (is (chain inventory
            (assoc-ref _ (basename a))
            (select-keys _ '(type mode))
            (equal? '((type . regular) (mode . #o444)) _)))
      (is (chain inventory
            (assoc-ref _ (basename b))
            (select-keys _ '(type mode))
            (equal? '((type . regular) (mode . #o444)) _)))

      (define registrations ((get ctx 'observe-db!) (list a b)))
      (is (chain registrations
            (assoc-ref _ a)
            (select-keys _ '(deriver references))
            (equal? '((deriver . #f) (references)) _)))
      (is (chain registrations
            (assoc-ref _ b)
            (select-keys _ '(deriver references))
            (equal? `((deriver . #f) (references ,a)) _)))

      ;; Compare the common DB facts with a fresh NAR of the observed file.
      (match-let (((left-root _) ((get ctx 'snapshot!))))
        (let-values (((hash size) (nar-sha256 (string-append left-root b))))
          (is (chain registrations
                (assoc-ref _ b)
                (select-keys _ '(nar-hash nar-size))
                (equal? `((nar-hash . ,(string-append "sha256:" (bytevector->base16-string hash)))
                          (nar-size . ,size))
                        _)))))))

  (test "adding valid text does not recreate its missing file" (ctx)
    (let* ((step! (get ctx 'step!))
           (observe-store! (get ctx 'observe-store!))
           (a (step! '(add-text-to-store "a-name" "a-content")
                     #:connection 'a))
           (b (step! `(add-text-to-store "b-name" "b-content" (,a))
                     #:connection 'a)))

      (is (chain (observe-store!)
            (assoc (basename b) _)))

      (is (chain `(valid-path? ,b)
            (step! _ #:connection 'a)
            (eq? #t _)))

      (delete-file (string-append (testbox-root (get ctx 'testbox/left)) b))
      (delete-file (string-append (testbox-root (get ctx 'testbox/right)) b))

      ;; A different reference list bypasses the client's add cache, but denotes
      ;; the same reference set and therefore the same destination.
      (is (chain `(add-text-to-store "b-name" "b-content" (,a ,a))
            (step! _ #:connection 'a)
            (equal? b _)))

      (is (chain `(valid-path? ,b)
            (step! _ #:connection 'a #:terminal? #t)
            (eq? #t _)))

      (is (chain (observe-store!)
            (assoc (basename b) _)
            (not _)))))

  (test "rejected text can be added after registering its missing reference" (ctx)
    (let* ((step! (get ctx 'step!))
           (observe-db! (get ctx 'observe-db!))
           (a (text-path "/gnu/store" "a-name" (string->utf8 "a-content") '()))
           (add-b `(add-text-to-store "b-name" "b-content" (,a))))

      (is (chain `(valid-path? ,a)
            (step! _ #:connection 'a)
            (eq? #f _)))

      (is (chain add-b
            (step! _ #:connection 'a)
            (equal? `((error/type . store-protocol-error)
                      (error/message . ,(string-append "path `" a "' is not valid"))
                      (error/status . 1))
                    _)))

      (is (chain '(add-text-to-store "a-name" "a-content")
            (step! _ #:connection 'a)
            (equal? a _)))

      (define b (step! add-b #:connection 'a))

      (is (chain `(valid-path? ,b)
            (step! _ #:connection 'a #:terminal? #t)
            (eq? #t _)))

      (is (chain (observe-db! (list b))
            (assoc-ref _ b)
            (get _ 'references)
            (equal? (list a) _))))))

(define-suite (server-derivation-tests)
  'metadata `((test/fixtures
               . ,(list (client-trust-fixture #f)
                        (paired-daemon-testboxes-fixture 'rootless 'nixd 'gxd)
                        paired-relay-observers-fixture
                        paired-snapshots-fixture database-observations-fixture)))

  (test "derivation registration records outputs and references without realizing outputs" (ctx)
    (define (make-drvs store)
      "Register the test derivations through STORE and return their records.
Each `derivation' call submits the serialized derivation through op 8;
outputs are not built."
      (let* ((multi (derivation store "multi" "/bin/sh" '()
                                #:system "x86_64-linux" #:outputs '("dev" "out")))
             (parent (derivation store "parent" "/bin/sh" '()
                                 #:system "x86_64-linux"
                                 #:inputs (list (derivation-input multi '("dev")))))
             (fixed (derivation store "fixed" "/bin/sh" '()
                                #:system "x86_64-linux"
                                #:hash (make-bytevector 32 17) #:hash-algo 'sha256))
             (fixed-parent (derivation store "fixed-parent" "/bin/sh" '()
                                       #:system "x86_64-linux"
                                       #:inputs (list (derivation-input fixed)))))
        (list multi parent fixed fixed-parent)))

    (define (expected-registration drv)
      "Return DRV's declared references and output mappings keyed by derivation path."
      (cons (derivation-file-name drv)
            `((references . ,(chain (derivation-inputs drv)
                               (map derivation-input-path _)
                               (append _ (derivation-sources drv))
                               (sort _ string<?)))
              (outputs . ,(derivation->output-paths drv)))))

    (define (outputs-valid? store drvs)
      "Query validity of each declared output, in DRVS and output order."
      (append-map
       (lambda (drv)
         (map (match-lambda ((_ . path) (valid-path? store path)))
              (derivation->output-paths drv)))
       drvs))

    (call-with-paired-clients
     (get ctx 'relay/left-endpoint)
     (get ctx 'relay/right-endpoint)
     (lambda (left right)
       (let* ((left-drvs (make-drvs left))
              (right-drvs (make-drvs right))
              (paths (map derivation-file-name left-drvs)))

         (is (equal? paths (map derivation-file-name right-drvs)))

         (define registrations ((get ctx 'observe-db!) paths))
         (define expected
           (chain left-drvs
             (map expected-registration _)
             (sort _ (match-lambda*
                       (((left-path . _) (right-path . _))
                        (string<? left-path right-path))))))

         ;; Derivations are registered with the expected references and outputs.
         (is (equal? expected
                     (map (match-lambda
                            ((path . facts)
                             (cons path (select-keys facts '(references outputs)))))
                          registrations)))

         ;; Derivation outputs have not been realized.
         (is (equal? '(#f #f #f #f #f) (outputs-valid? left left-drvs)))
         (is (equal? '(#f #f #f #f #f) (outputs-valid? right right-drvs))))))

    (match-let (((left-bytes right-bytes) ((get ctx 'observe-bytes!))))
      (is (bytevector=? left-bytes right-bytes)))))

(define-suite (server-rejected-derivation-tests)
  'metadata `((test/fixtures . ,derivation-test-fixtures))

  (test "incorrect derivation output prevents registration but permits another request" (ctx)
    (define registration-outcome! (get ctx 'registration-outcome!))

    (define drv (test-derivation))

    ;; Change only the declared output path; keep the original environment.
    (define drv-output (assoc-ref (derivation-outputs drv) "out"))
    (define valid-output-path (derivation-output-path drv-output))

    (define invalid-output-path "/gnu/store/00000000000000000000000000000000-invalid")
    (define drv-with-invalid-output
      (set-fields drv
        ((derivation-outputs)
         (list (cons "out" (set-fields drv-output ((derivation-output-path) invalid-output-path)))))))

    (define invalid-drv-path (derivation-text-path "example.drv" drv-with-invalid-output))

    ;; Rejection leaves no registration and both connections usable.
    (is (equal? `((response . ,(incorrect-output-error invalid-drv-path
                                                       invalid-output-path
                                                       valid-output-path))
                  (registration . ())
                  (connection-usable? . #t))
                (registration-outcome! "example.drv" drv-with-invalid-output))))

  (test "incorrect or missing output environment prevents derivation registration" (ctx)
    (define registration-outcome! (get ctx 'registration-outcome!))

    (define drv (test-derivation))
    (define valid-output-path (assoc-ref (derivation->output-paths drv) "out"))
    (define env-missing-out (alist-delete "out" (derivation-builder-environment-vars drv)))

    (define (expected-rejection drv)
      "Return the expected error, absent registration and usable-connection facts for DRV."
      `((response . ,(incorrect-output-error (derivation-text-path "example.drv" drv)
                                             valid-output-path valid-output-path))
        (registration . ())
        (connection-usable? . #t)))

    ;; A correct output declaration cannot compensate for an incorrect environment.
    (define drv-invalid-out-env
      (set-fields drv
        ((derivation-builder-environment-vars)
         (acons "out" "/gnu/store/invalid" env-missing-out))))

    ;; Missing output variables are rejected too, rather than supplied by the daemon.
    (define drv-missing-out-env
      (set-fields drv ((derivation-builder-environment-vars) env-missing-out)))

    (is (equal? (expected-rejection drv-invalid-out-env)
                (registration-outcome! "example.drv" drv-invalid-out-env #:terminal? #f)))

    (is (equal? (expected-rejection drv-missing-out-env)
                (registration-outcome! "example.drv" drv-missing-out-env)))))

(define-suite (server-invalid-derivation-hash-tests)
  'metadata `((test/fixtures . ,derivation-test-fixtures))

  (test "invalid fixed-output hashes prevent registration without closing the session" (ctx)
    (define registration-outcome! (get ctx 'registration-outcome!))

    (define drv (test-derivation))
    (define drv-output (assoc-ref (derivation-outputs drv) "out"))

    (define drv-unknown-algorithm
      (set-fields drv
        ((derivation-outputs)
         (list (cons "out"
                     (set-fields drv-output
                       ((derivation-output-hash-algo) 'unknown)
                       ((derivation-output-hash) (make-bytevector 32 17))))))))

    (define drv-short-hash
      (set-fields drv
        ((derivation-outputs)
         (list (cons "out"
                     (set-fields drv-output
                       ((derivation-output-hash-algo) 'sha256)
                       ((derivation-output-hash) (make-bytevector 1 17))))))))

    (is (equal? '((response . ((error/type . store-protocol-error)
                               (error/message . "unknown hash algorithm `unknown'")
                               (error/status . 1)))
                  (registration . ())
                  (connection-usable? . #t))
                (registration-outcome! "example.drv" drv-unknown-algorithm #:terminal? #f))
        "unknown hash algorithm rejects registration and leaves the session usable")

    (is (equal? '((response . ((error/type . store-protocol-error)
                               (error/message . "invalid SHA256 hash '11' (1 bytes but expected 32)")
                               (error/status . 1)))
                  (registration . ())
                  (connection-usable? . #t))
                (registration-outcome! "example.drv" drv-short-hash))
        "short SHA256 digest rejects registration and leaves the session usable")))

(define-suite (server-invalid-text-tests)
  'metadata `((test/fixtures
               . ,(list (client-trust-fixture #f)
                        (paired-daemon-testboxes-fixture 'rootless 'nixd 'gxd)
                        paired-relay-observers-fixture)))

  (test "outside-store text references report an error and close the connection" (ctx)
    (call-with-paired-clients
     (get ctx 'relay/left-endpoint)
     (get ctx 'relay/right-endpoint)
     (lambda (left right)
       (is (chain '(add-text-to-store "b-name" "b-content" ("/outside"))
             (paired-step! left right _)
             (equal? '((error/type . store-protocol-error)
                       (error/message . "path `/outside' is not in the store")
                       (error/status . 1))
                     _)))

       (is (remote-eof? left))
       (is (remote-eof? right))))

    (match-let (((left-bytes right-bytes) ((get ctx 'observe-bytes!))))
      (is (bytevector=? left-bytes right-bytes)))))

(define-suite (server-tests)
  'metadata `((test/fixtures . ,(paired-testbox-fixtures 'rootless 'nixd 'gxd)))

  (test "build options can be set before and after other ops on one connection" (ctx)
    (let* ((step! (get ctx 'step!))
           (present (direct-store-path
                     (canonicalize-path (require-program "guix-daemon"))))
           (absent "/gnu/store/00000000000000000000000000000000-gxd-absent"))

      (is (chain '(set-build-options #:user-name #f #:terminal-columns #f #:locale #f
                                     #:offload? #f #:use-substitutes? #f
                                     #:max-build-jobs 1 #:timeout 12
                                     #:multiplexed-build-output? #t)
            (step! _ #:connection 'a)
            (null? _)))

      (is (chain `(valid-path? ,present)
            (step! _ #:connection 'a)
            (eq? #t _)))

      (is (chain '(valid-path? "/outside")
            (step! _ #:connection 'a)
            (equal? '((error/type . store-protocol-error)
                      (error/message . "path `/outside' is not in the store")
                      (error/status . 1))
                    _)))

      (is (chain '(set-build-options #:user-name #f #:terminal-columns #f #:locale #f
                                     #:offload? #t #:use-substitutes? #t
                                     #:max-build-jobs 2 #:timeout 24)
            (step! _ #:connection 'a)
            (null? _)))

      (is (chain `(valid-path? ,absent)
            (step! _ #:connection 'a #:terminal? #t)
            (eq? #f _)))))

  (test "validity queries continue after an outside-store error on one connection" (ctx)
    (let* ((step! (get ctx 'step!))
           (present (direct-store-path
                     (canonicalize-path (require-program "guix-daemon"))))
           (absent "/gnu/store/00000000000000000000000000000000-gxd-absent"))

      (is (chain `(valid-path? ,present)
            (step! _ #:connection 'a)
            (eq? #t _)))

      (is (chain '(valid-path? "/outside")
            (step! _ #:connection 'a)
            (equal? '((error/type . store-protocol-error)
                      (error/message . "path `/outside' is not in the store")
                      (error/status . 1))
                    _)))

      (is (chain `(valid-path? ,absent)
            (step! _ #:connection 'a #:terminal? #t)
            (eq? #f _)))))

  (test "registered path is valid on nixd and gxd" (ctx)
    (let ((step! (get ctx 'step!))
          (path (direct-store-path
                 (canonicalize-path (require-program "guix-daemon")))))
      (is (eq? #t (step! `(valid-path? ,path))))))

  (test "unregistered path is invalid on nixd and gxd" (ctx)
    (let ((step! (get ctx 'step!)))
      (is (eq? #f (step! '(valid-path? "/gnu/store/00000000000000000000000000000000-gxd-absent"))))))

  (test "outside-store path has the same protocol error on nixd and gxd" (ctx)
    (let ((step! (get ctx 'step!)))
      (is (equal? '((error/type . store-protocol-error)
                    (error/message . "path `/outside' is not in the store")
                    (error/status . 1))
                  (step! '(valid-path? "/outside")))))))

(define-suite (server-invalid-options-tests)
  'metadata `((test/fixtures
               . ,(list (client-trust-fixture #f)
                        (paired-daemon-testboxes-fixture 'rootless 'nixd 'gxd)
                        paired-relay-observers-fixture)))

  (test "an invalid option value reports an error and closes the connection" (ctx)
    (let ((present (direct-store-path
                    (canonicalize-path (require-program "guix-daemon")))))
      (call-with-paired-clients
       (get ctx 'relay/left-endpoint)
       (get ctx 'relay/right-endpoint)
       (lambda (left right)
         (is (chain `(valid-path? ,present)
               (paired-step! left right _)
               (eq? #t _)))

         ;; The client sends 1/2 as "1/2"; the daemon validates the integer.
         (is (chain '(set-build-options #:user-name #f #:terminal-columns #f
                                        #:locale #f #:offload? #f
                                        #:use-substitutes? #f #:timeout 1/2)
               (paired-step! left right _)
               (equal? '((error/type . store-protocol-error)
                         (error/message . "configuration setting `build-timeout' should have an integer value")
                         (error/status . 1))
                       _)))

         (is (remote-eof? left))
         (is (remote-eof? right)))))

    (match-let (((left-bytes right-bytes) ((get ctx 'observe-bytes!))))
      (is (bytevector=? left-bytes right-bytes)))))
