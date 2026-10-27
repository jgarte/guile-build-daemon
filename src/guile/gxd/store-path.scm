;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd store-path)
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module ((guix store)
                #:prefix guix-store:
                #:select (%store-prefix store-path fixed-output-path))
  #:use-module ((ice-9 exceptions) #:select (&error define-exception-type
                                             raise-exception))
  #:export (text-path fixed-output-path store-path? check-store-name &store-name-error store-name-error?
                      store-name-error-name leading-dot-name-error?
                      invalid-character-name-error? invalid-character-name-error-character))

(define-exception-type &store-name-error &error
  make-store-name-error store-name-error?
  (name store-name-error-name))

(define-exception-type &leading-dot-name-error &store-name-error
  make-leading-dot-name-error leading-dot-name-error?)

(define-exception-type &invalid-character-name-error &store-name-error
  make-invalid-character-name-error invalid-character-name-error?
  (character invalid-character-name-error-character))

(define (store-path? store-directory path)
  "Return whether PATH names an immediate item beneath STORE-DIRECTORY."
  (let ((prefix (string-append store-directory "/")))
    (and (string-prefix? prefix path)
         (> (string-length path) (string-length prefix))
         (not (string-index path #\/ (string-length prefix))))))

(define (check-store-name name)
  "Raise a store-name error when NAME is invalid."
  (when (string-prefix? "." name)
    (raise-exception (make-leading-dot-name-error name)))

  (string-for-each
   (lambda (character)
     (unless (or (char<=? #\A character #\Z)
                 (char<=? #\a character #\z)
                 (char<=? #\0 character #\9)
                 (string-index "+-._?=" character))
       (raise-exception (make-invalid-character-name-error name character))))
   name))

(define (text-path store-directory name contents references)
  "Return the text store path for NAME and bytevector CONTENTS in STORE-DIRECTORY.
REFERENCES must be sorted unique store paths, validated by the caller.
Raise a store-name error when NAME is invalid."
  (check-store-name name)
  (let ((type (string-append
               "text" (string-concatenate
                       (map (lambda (reference) (string-append ":" reference))
                            references))))
        (hash (sha256 contents)))
    (parameterize ((guix-store:%store-prefix store-directory))
      (guix-store:store-path type hash name))))

(define* (fixed-output-path store-directory name hash
                            #:key (hash-algo 'sha256) (recursive? #t))
  "Return the fixed-output store path for NAME and HASH in STORE-DIRECTORY.
HASH-ALGO is a hash-algorithm symbol.  RECURSIVE? selects NAR hashing rather
than flat-file hashing.  Raise a store-name error when NAME is invalid."
  (check-store-name name)
  (parameterize ((guix-store:%store-prefix store-directory))
    (guix-store:fixed-output-path name hash
                                  #:hash-algo hash-algo
                                  #:recursive? recursive?)))
