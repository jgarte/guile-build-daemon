;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd manifest)
  #:use-module ((gxd env dev packages) #:select (dev-env))
  #:use-module (guix profiles))

(packages->manifest dev-env)
