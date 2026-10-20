;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd store-path)
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module ((guix store)
                #:prefix guix-store:
                #:select (%store-prefix store-path))
  #:use-module ((ice-9 exceptions) #:select (&error define-exception-type
                                                    raise-exception))
  #:use-module ((ice-9 format) #:select (format))
  #:export (text-path &store-name-error store-name-error?
                      store-name-error-message))

(define-exception-type &store-name-error &error
  make-store-name-error store-name-error?
  (message store-name-error-message))

(define (check-store-name name)
  (when (string-prefix? "." name)
    (raise-exception
     (make-store-name-error
      (format #f "invalid name: `~a' (can't begin with dot)" name))))

  (string-for-each
   (lambda (character)
     (unless (or (char<=? #\A character #\Z)
                 (char<=? #\a character #\z)
                 (char<=? #\0 character #\9)
                 (string-index "+-._?=" character))
       (raise-exception
        (make-store-name-error
         (format #f "invalid character `~a' in name `~a'" character name)))))
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
