;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd server-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix store) #:select (direct-store-path store-connection-socket))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((rnrs io ports) #:select (lookahead-u8))
  #:use-module ((gxd direct-steps) #:select (call-with-client paired-step!))
  #:use-module ((gxd test-fixtures) #:select (paired-testbox-fixtures))
  #:use-module (gxd test-prelude)
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture))
  #:use-module ((gxd testbox snapshots) #:select (paired-snapshots-fixture))
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
                          (list paired-snapshots-fixture store-observations-fixture))))

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
            (equal? '((type . regular) (mode . #o444)) _))))))

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
      (call-with-client (get ctx 'relay/left-endpoint)
        (lambda (left)
          (call-with-client (get ctx 'relay/right-endpoint)
            (lambda (right)
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
              (is (remote-eof? right)))))))

    (match-let (((left-bytes right-bytes) ((get ctx 'observe-bytes!))))
      (is (bytevector=? left-bytes right-bytes)))))
