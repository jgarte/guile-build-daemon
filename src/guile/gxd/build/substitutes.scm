;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (gxd build substitutes)
  #:use-module (gxd prelude)
  #:use-module (gxd build config)
  #:use-module ((gxd database) #:prefix database:)
  #:use-module (gxd path-locks)
  #:use-module (gxd store-files)
  #:use-module (guix narinfo)
  #:use-module (guix substitutes)
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((srfi srfi-1) #:select (every filter)))

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
