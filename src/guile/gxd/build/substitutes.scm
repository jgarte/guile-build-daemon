;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build substitutes)
  #:use-module (gxd prelude)
  #:use-module ((gxd build config) #:select (build-store-directory build-use-substitutes?))
  #:use-module ((gxd database) #:prefix database:
                #:select (valid-path? make-output-info register-outputs!))
  #:use-module ((gxd path-locks) #:select (call-with-destination-locks))
  #:use-module ((gxd store-files) #:select (delete-path! rename-path!))
  #:use-module ((guix narinfo) #:select (valid-narinfo? narinfo-references narinfo-path
                                         narinfo-size narinfo-hash-algorithm+value narinfo-deriver))
  #:use-module ((gcrypt hash) #:select (hash-algorithm sha256))
  #:use-module ((guix substitutes) #:select (lookup-narinfos/diverse download-nar))
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((srfi srfi-1) #:select (filter delete-duplicates))
  #:export (substitute-paths!))

(define (narinfo-reference-paths info)
  "Return INFO's references as full paths in its store directory."
  (define directory (dirname (narinfo-path info)))
  (map (lambda (name) (string-append directory "/" name))
       (narinfo-references info)))

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
               (for-each visit (narinfo-reference-paths info))
               (set! result (cons info result))))))
       (for-each visit paths)
       (reverse result)))))

(define (download-verified! info destination)
  "Restore INFO at private DESTINATION and verify its declared hash.
Return the NAR SHA256 and size for registration."
  (let-values (((expected actual) (download-nar info destination #:fetch-timeout #f))
               ((algorithm _) (narinfo-hash-algorithm+value info)))
    (unless (bytevector=? expected actual)
      (error "substitute hash mismatch" (narinfo-path info)))
    (if (= algorithm (hash-algorithm sha256))
        (values actual (narinfo-size info))
        (nar-sha256 destination))))

(define (install-substitute! db info config)
  "Verify INFO privately, then publish and register its store item.
The caller holds its destination lock and excludes concurrent invalidation."
  (let* ((destination-path (narinfo-path info))
         (store-directory (build-store-directory config))
         (deriver (narinfo-deriver info))
         (deriver-path (and deriver (string-append (dirname destination-path) "/" deriver)))
         (directory (mkdtemp! (string-append store-directory "/.substitute.XXXXXX")))
         (staged-path (string-append directory "/restored")))
    (call-with-cleanup
     (lambda () (delete-path! directory))
     (lambda ()
       (let-values (((hash size) (download-verified! info staged-path)))
         (define output
           (database:make-output-info
            destination-path hash size
            (sort (delete-duplicates (narinfo-reference-paths info)) string<?)))

         (delete-path! destination-path)
         (rename-path! staged-path destination-path)
         (database:register-outputs! db store-directory deriver-path (list output))
         'substituted)))))

(define (substitute-paths! db paths config)
  "Substitute missing PATHS and their references, or return #f on a lookup miss.
The caller excludes concurrent invalidation.  Transfer and integrity errors propagate."
  (and (build-use-substitutes? config)
       (let ((infos (lookup-closure db paths)))
         (and infos
              (call-with-destination-locks (map narinfo-path infos)
                (lambda ()
                  (for-each
                   (lambda (info)
                     (unless (database:valid-path? db (narinfo-path info))
                       (install-substitute! db info config)))
                   infos)
                  'substituted))))))
