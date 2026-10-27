;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd derivation-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix store) #:select (add-text-to-store direct-store-path valid-path?))
  #:use-module ((guix derivations)
                #:select (derivation derivation-input derivation-file-name
                          derivation->output-paths derivation-inputs
                          derivation-input-path derivation-sources
                          derivation-outputs derivation-output-path
                          derivation-output-hash derivation-output-hash-algo
                          write-derivation
                          derivation-builder-environment-vars))
  #:use-module ((ice-9 match) #:select (match-let match-lambda match-lambda*))
  #:use-module ((srfi srfi-1) #:select (append-map alist-delete))
  #:use-module ((rnrs bytevectors) #:select (bytevector=? string->utf8 make-bytevector))
  #:use-module ((srfi srfi-9 gnu) #:select (set-fields))
  #:use-module ((gxd direct-steps) #:select (call-with-paired-clients))
  #:use-module ((gxd store-path) #:select (text-path))
  #:use-module ((gxd test-fixtures) #:select (paired-testbox-fixtures))
  #:use-module (gxd test-prelude)
  #:use-module ((gxd testbox snapshots) #:select (paired-snapshots-fixture))
  #:use-module ((gxd testbox database-observations) #:select (database-observations-fixture)))

(define (derivation->text drv)
  "Return the serialized derivation for DRV."
  (call-with-output-string
   (lambda (port) (write-derivation drv port))))

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
  (define observe-db-path! (get ctx 'observe-db-path!))
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
           (registration (observe-db-path! path))
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

(define-suite (server-derivation-tests)
  'metadata `((test/fixtures . ,derivation-test-fixtures))

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
                  (registration . #f)
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
        (registration . #f)
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

(define-suite (server-derivation-order-tests)
  'metadata `((test/fixtures . ,derivation-test-fixtures))

  (test "reversed output declarations retain their canonical output paths" (ctx)
    (define step! (get ctx 'step!))
    (define observe-db-path! (get ctx 'observe-db-path!))

    (let* ((drv (test-derivation #:output-names '("dev" "out")))
           (reversed-drv
            (set-fields drv
              ((derivation-outputs) (reverse (derivation-outputs drv)))))
           (reversed-text (derivation->text reversed-drv))
           (reversed-path (derivation-text-path "example.drv" reversed-drv)))

      (chain (step! `(add-text-to-store "example.drv" ,reversed-text)
                    #:connection 'derivation #:terminal? #t)
        (equal? reversed-path _)
        (is _ "reversed declarations are accepted at the expected derivation path"))

      (chain (observe-db-path! reversed-path)
        (get _ 'outputs)
        (equal? (derivation->output-paths drv) _)
        (is _ "registration retains the canonical output mappings"))))

  (test "reversed invalid declarations report the lexically first output" (ctx)
    (define registration-outcome! (get ctx 'registration-outcome!))

    (let* ((drv (test-derivation #:output-names '("dev" "out")))
           (invalid-output-path "/gnu/store/00000000000000000000000000000000-invalid")
           (invalid-drv
            (set-fields drv
              ((derivation-outputs)
               (map (match-lambda
                      ((name . output)
                       (cons name (set-fields output ((derivation-output-path) invalid-output-path)))))
                    (reverse (derivation-outputs drv))))))
           (invalid-drv-path (derivation-text-path "example.drv" invalid-drv))
           (expected-dev-path (assoc-ref (derivation->output-paths drv) "dev")))

      (chain (registration-outcome! "example.drv" invalid-drv)
        (equal? `((response . ,(incorrect-output-error
                                invalid-drv-path invalid-output-path expected-dev-path))
                  (registration . #f)
                  (connection-usable? . #t))
                _)
        (is _ "dev is rejected before out, registration stays absent, and the session remains usable"))))

  (test "reversed input environment retains canonical parent output paths" (ctx)
    (define (register-parent store)
      "Register an input with reversed environment, then its canonically hashed parent."
      (let* ((drv (test-derivation #:output-names '("dev" "out")))
             (drv-with-reversed-env
              (set-fields drv
                ((derivation-builder-environment-vars)
                 (reverse (derivation-builder-environment-vars drv)))))
             (input-path
              (add-text-to-store store "example.drv" (derivation->text drv-with-reversed-env)))
             (input-drv (set-fields drv ((derivation-file-name) input-path))))
        (derivation store "parent" "/bin/sh" '()
                    #:system "x86_64-linux"
                    #:inputs (list (derivation-input input-drv '("dev"))))))

    (call-with-paired-clients
     (get ctx 'relay/left-endpoint)
     (get ctx 'relay/right-endpoint)
     (lambda (left right)
       (let ((left-parent (register-parent left))
             (right-parent (register-parent right)))
         (is (equal? (derivation-file-name left-parent) (derivation-file-name right-parent))
             "both daemons register the parent with output paths computed from the canonically ordered input"))))

    (match-let (((left-bytes right-bytes) ((get ctx 'observe-bytes!))))
      (is (bytevector=? left-bytes right-bytes)))))

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
                  (registration . #f)
                  (connection-usable? . #t))
                (registration-outcome! "example.drv" drv-unknown-algorithm #:terminal? #f))
        "unknown hash algorithm rejects registration and leaves the session usable")

    (is (equal? '((response . ((error/type . store-protocol-error)
                               (error/message . "invalid SHA256 hash '11' (1 bytes but expected 32)")
                               (error/status . 1)))
                  (registration . #f)
                  (connection-usable? . #t))
                (registration-outcome! "example.drv" drv-short-hash))
        "short SHA256 digest rejects registration and leaves the session usable")))

(define-suite (server-invalid-derivation-name-tests)
  'metadata `((test/fixtures . ,derivation-test-fixtures))

  (test "invalid output name prevents registration without closing the session" (ctx)
    (define registration-outcome! (get ctx 'registration-outcome!))

    (define drv (test-derivation))
    (define drv-output (assoc-ref (derivation-outputs drv) "out"))

    ;; The output ID makes the resultant store name `example-bad/id' invalid.
    ;; Leave the output path intact: name validation must precede path comparison.
    (define drv-invalid-output-name
      (set-fields drv ((derivation-outputs) (list (cons "bad/id" drv-output)))))

    (is (equal? '((response . ((error/type . store-protocol-error)
                               (error/message . "invalid character `/' in name `example-bad/id'")
                               (error/status . 1)))
                  (registration . #f)
                  (connection-usable? . #t))
                (registration-outcome! "example.drv" drv-invalid-output-name))
        "invalid output name rejects registration and leaves the session usable")))
