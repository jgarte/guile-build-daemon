;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd roots)
  #:use-module (gxd prelude)
  #:use-module ((gcrypt hash) #:select (sha1))
  #:use-module ((guix base32) #:select (bytevector->nix-base32-string))
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:use-module ((srfi srfi-1) #:select (fold))
  #:use-module ((srfi srfi-13) #:select (string-join string-prefix?))
  #:export (register-indirect-root!))

;; Guix's `absolute-file-name' resolves symlinks; preserve the root link's path.
(define (absolute-root-path path)
  "Return PATH made absolute and lexically normalized, without resolving symlinks."
  (let* ((absolute (if (string-prefix? "/" path) path (string-append (getcwd) "/" path)))
         (components
          (fold (lambda (component result)
                  (cond
                   ((member component '("" ".")) result)
                   ((string=? component "..") (if (null? result) result (cdr result)))
                   (else (cons component result))))
                '() (string-split absolute #\/))))
    (string-append "/" (string-join (reverse components) "/"))))

(define (register-indirect-root! state-directory path)
  "Register PATH as an indirect GC root under STATE-DIRECTORY."
  (let* ((target (absolute-root-path path))
         (directory (string-append state-directory "/gcroots/auto"))
         (link (string-append directory "/"
                              (bytevector->nix-base32-string (sha1 (string->utf8 target)))))
         (temporary (string-append link ".tmp-" (number->string (getpid)) "-"
                                   (number->string (random (expt 2 32))))))
    (mkdir-p directory)
    (symlink target temporary)
    (rename-file temporary link)))
