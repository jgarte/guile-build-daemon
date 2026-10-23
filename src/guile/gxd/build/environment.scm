;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build environment)
  #:use-module (gxd prelude)
  #:use-module ((guix derivations) #:select (derivation-builder-environment-vars))
  #:use-module ((ice-9 match) #:select (match-lambda*))
  #:use-module ((srfi srfi-1) #:select (fold alist-delete))
  #:export (build-environment))

(define replace-binding
  (match-lambda*
    (((name . value) environment)
     (acons name value (alist-delete name environment string=?)))))

(define binding-name<?
  (match-lambda*
    (((left-name . _) (right-name . _))
     (string<? left-name right-name))))

(define (build-environment drv store-directory build-directory cores)
  "Return a name-sorted environment alist for DRV, without inherited variables.
Use STORE-DIRECTORY and CORES for defaults, overridden by DRV's bindings.
Override build-directory variables with BUILD-DIRECTORY afterward."
  (define defaults
    `(("PATH" . "/path-not-set")
      ("HOME" . "/homeless-shelter")
      ("NIX_STORE" . ,store-directory)
      ("NIX_BUILD_CORES" . ,(number->string cores))))

  (chain (append defaults
                 (derivation-builder-environment-vars drv)
                 `(("NIX_BUILD_TOP" . ,build-directory)
                   ("TMPDIR" . ,build-directory)
                   ("TEMPDIR" . ,build-directory)
                   ("TMP" . ,build-directory)
                   ("TEMP" . ,build-directory)
                   ("PWD" . ,build-directory)))
    (fold replace-binding '() _)
    (sort _ binding-name<?)))
