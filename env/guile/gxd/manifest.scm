;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd manifest)
  #:use-module (gnu packages)
  #:use-module (gnu packages package-management)
  #:use-module (gxd env dev packages)
  #:use-module (guix profiles))

(packages->manifest
 ;; `current-guix' package metadata gets inherited from `guix' package;
 ;; but the source is as of the guix which executes this manifest
 (cons* (current-guix)
        guile-ares-rs-latest
        (map specification->package
             '("guile"))))
