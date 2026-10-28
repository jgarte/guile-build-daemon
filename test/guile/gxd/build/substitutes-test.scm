;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (gxd build substitutes-test)
  #:use-module (gxd test-prelude)
  #:use-module (gxd build config)
  #:use-module (gxd build substitutes)
  #:use-module ((guix narinfo) #:select (read-narinfo))
  #:use-module ((guix serialization) #:select (write-file))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((guix base32) #:select (bytevector->nix-base32-string))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((gxd test-database) #:select (call-with-empty-database))
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((ares suitbl core) #:select (define-suite test is)))

(define (local-narinfo path nar hash size)
  (call-with-input-string
      (format #f "StorePath: ~a~%URL: file://~a~%Compression: none~%NarHash: sha256:~a~%NarSize: ~a~%References:~%"
              path nar (bytevector->nix-base32-string hash) size)
    read-narinfo))

(define-suite (substitute-tests)
  (test "disabled substitution does not access the database or network" ()
    (is (not (substitute-paths! #f '("unused")
                               (build-config #:use-substitutes? #f)))))
  (test "a missing substitute returns false without creating files" ()
    (call-with-empty-database
     (lambda (db directory)
       (parameterize ((substitute-urls '()))
         (is (not (substitute-paths!
                   db (list (string-append directory "/missing"))
                   (build-config #:use-substitutes? #t
                                 #:store-directory "/does-not-exist")))))))))
