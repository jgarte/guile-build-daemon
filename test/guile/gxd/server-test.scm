;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd server-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix store) #:select (direct-store-path store-connection-socket))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((rnrs bytevectors) #:select (bytevector=? string->utf8))
  #:use-module ((rnrs io ports) #:select (lookahead-u8))
  #:use-module ((srfi srfi-11) #:select (let-values))
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
           (observe-db-path! (get ctx 'observe-db-path!))
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

      (is (chain (observe-db-path! b)
            (get _ 'references)
            (equal? (list a) _))))))

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
