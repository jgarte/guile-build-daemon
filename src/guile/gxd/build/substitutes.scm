;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build substitutes)
  #:use-module (gxd prelude)
  #:use-module ((gxd build config) #:select (build-store-directory))
  #:use-module ((gxd database) #:prefix database:
                #:select (valid-path? make-output-info register-outputs!))
  #:use-module ((gxd path-locks) #:select (call-with-destination-lock))
  #:use-module ((gxd store-files) #:select (delete-path! rename-path!))
  #:use-module ((guix narinfo) #:select (valid-narinfo? narinfo-references narinfo-path
                                         narinfo-size narinfo-hash-algorithm+value narinfo-deriver
                                         narinfo-uris))
  #:use-module ((gcrypt hash) #:select (hash-algorithm sha256))
  #:use-module ((guix substitutes) #:select (lookup-narinfos/diverse download-nar))
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module ((ice-9 exceptions) #:select (&error define-exception-type raise-exception))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates every))
  #:use-module ((web uri) #:select (uri-scheme))
  #:export (substitute-path!))

(define-exception-type &substitute-hash-mismatch &error
  make-substitute-hash-mismatch substitute-hash-mismatch?
  (path substitute-hash-mismatch-path))

(define-exception-type &unsafe-substitute-uri &error
  make-unsafe-substitute-uri unsafe-substitute-uri?
  (path unsafe-substitute-uri-path))

(define (narinfo-reference-paths info)
  "Return INFO's references as full paths in its store directory."
  (define directory (dirname (narinfo-path info)))
  (map (lambda (name) (string-append directory "/" name))
       (narinfo-references info)))

(define (download-verified! info destination)
  "Restore INFO at private DESTINATION and verify its declared hash.
Return the NAR SHA256 and size for registration."
  (let-values (((expected actual) (download-nar info destination #:fetch-timeout #f))
               ((algorithm _) (narinfo-hash-algorithm+value info)))
    (unless (bytevector=? expected actual)
      (raise-exception (make-substitute-hash-mismatch (narinfo-path info))))
    (if (= algorithm (hash-algorithm sha256))
        (values actual (narinfo-size info))
        (nar-sha256 destination))))

(define (narinfo-uris-safe? info)
  (every (lambda (uri) (not (memq (uri-scheme uri) '(#f file))))
         (narinfo-uris info)))

(define (fetch-output-info! info staged-path)
  "Restore INFO at STAGED-PATH, returning its registration facts."
  (let-values (((hash size) (download-verified! info staged-path)))
    (database:make-output-info
     (narinfo-path info) hash size
     (sort (delete-duplicates (narinfo-reference-paths info)) string<?))))

(define (install-substitute! db info config)
  "Verify INFO privately, then publish and register its store item.
The caller holds its destination lock and excludes concurrent invalidation."
  ;; Archive URLs are not covered by the narinfo's signed content hash.
  (unless (narinfo-uris-safe? info)
    (raise-exception (make-unsafe-substitute-uri (narinfo-path info))))
  (let* ((destination-path (narinfo-path info))
         (store-directory (build-store-directory config))
         (deriver (narinfo-deriver info))
         (deriver-path (and deriver (string-append (dirname destination-path) "/" deriver)))
         (directory (mkdtemp! (string-append store-directory "/.substitute.XXXXXX")))
         (staged-path (string-append directory "/restored")))
    (call-with-cleanup
     (lambda () (delete-path! directory))
     (lambda ()
       (define output (fetch-output-info! info staged-path))

       (delete-path! destination-path)
       (rename-path! staged-path destination-path)
       (database:register-outputs! db store-directory deriver-path (list output))
       'substituted))))

(define (substitute-path! db path config)
  "Substitute PATH after its runtime references, retaining completed registrations.
Return 'satisfied, 'unavailable, or 'incomplete-closure.  The caller excludes
concurrent invalidation; transfer and integrity errors propagate."
  (if (database:valid-path? db path)
      'satisfied
      (match (lookup-narinfos/diverse (substitute-urls) (list path) valid-narinfo?)
        (() 'unavailable)
        ((info . _)
         (define (substitute-reference! reference)
           (or (string=? reference path)
               (eq? 'satisfied (substitute-path! db reference config))))

         (if (every substitute-reference! (narinfo-reference-paths info))
             (call-with-destination-lock path
               (lambda ()
                 (unless (database:valid-path? db path)
                   (install-substitute! db info config))
                 'satisfied))
             'incomplete-closure)))))
