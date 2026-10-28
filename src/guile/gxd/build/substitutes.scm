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
  #:use-module ((gxd store-files) #:select (delete-path! canonicalize-metadata!))
  #:use-module ((guix narinfo) #:select (valid-narinfo? narinfo-references narinfo-path
                                         narinfo-size narinfo-hash-algorithm+value))
  #:use-module ((gcrypt hash) #:select (hash-algorithm sha256))
  #:use-module ((guix substitutes) #:select (lookup-narinfos/diverse download-nar))
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((guix build syscalls) #:select (mkdtemp!))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((srfi srfi-1) #:select (filter delete-duplicates))
  #:export (substitute-paths!))

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

(define (install-closure! db infos config)
  "Verify INFOS privately, then publish and register them under destination locks."
  (define directory
    (mkdtemp! (string-append (build-store-directory config) "/.substitute.XXXXXX")))

  (define (staged info)
    (string-append directory "/" (basename (narinfo-path info))))

  (call-with-cleanup
   (lambda () (delete-path! directory))
   (lambda ()
     (define outputs (map (lambda (info) (download-verified! info (staged info))) infos))

     (for-each (lambda (info)
                 (delete-path! (narinfo-path info))
                 (rename-file (staged info) (narinfo-path info)))
               infos)
     (database:register-outputs! db (build-store-directory config) #f outputs)
     'substituted)))

(define (substitute-paths! db paths config)
  "Substitute missing PATHS and their references, or return #f on a lookup miss.
The caller excludes concurrent invalidation.  Transfer and integrity errors propagate."
  (and (build-use-substitutes? config)
       (let ((infos (lookup-closure db paths)))
         (and infos
              (call-with-destination-locks (map narinfo-path infos)
                (lambda ()
                  (install-closure!
                   db (filter (lambda (info)
                                (not (database:valid-path? db (narinfo-path info))))
                              infos)
                   config)))))))
