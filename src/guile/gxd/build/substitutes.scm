;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (gxd build substitutes)
  #:use-module (gxd prelude)
  #:use-module (gxd build config)
  #:use-module ((gxd database) #:prefix database:)
  #:use-module (gxd path-locks)
  #:use-module (gxd store-files)
  #:use-module (guix narinfo)
  #:use-module ((gcrypt hash) #:select (hash-algorithm sha256))
  #:use-module (guix substitutes)
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((srfi srfi-1) #:select (every filter delete-duplicates)))

(define (lookup-closure db paths)
  "Return trusted narinfos for missing PATHS and references, or #f on a miss."
  (call/cc
   (lambda (missing)
     (let ((seen '()) (result '()))
       (define (visit path)
         (unless (or (database:valid-path? db path) (member path seen))
           (set! seen (cons path seen))
           (let ((hits (lookup-narinfos/diverse
                        (substitute-urls) (list path) valid-narinfo?)))
             (when (null? hits) (missing #f))
             (let ((info (car hits)))
               (for-each visit (narinfo-references info))
               (set! result (cons info result))))))
       (for-each visit paths)
       (reverse result)))))

(define (download-verified! info destination)
  "Restore INFO at private DESTINATION; reject unsupported or mismatched hashes."
  (call-with-values (lambda () (narinfo-hash-algorithm+value info))
    (lambda (algorithm hash)
      (unless (= algorithm (hash-algorithm sha256))
        (error "unsupported substitute hash algorithm" algorithm))))
  (call-with-values (lambda () (download-nar info destination))
    (lambda (expected actual)
      (unless (bytevector=? expected actual)
        (error "substitute hash mismatch" (narinfo-path info)))
      (canonicalize-metadata! destination)
      (database:make-output-info
       (narinfo-path info) actual (narinfo-size info)
       (sort (delete-duplicates (narinfo-references info)) string<?)))))
