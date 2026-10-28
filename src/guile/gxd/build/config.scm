;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build config)
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:export (build-config build-mode build-store-directory build-directory-parent build-cores build-sandboxed?
                         build-use-substitutes?
                         build-guix-program build-daemon-environment build-options))

(define-record-type <build-config>
  (build-config-positional mode store-directory directory-parent cores sandboxed? guix-program environment use-substitutes? options)
  build-config?
  (mode build-mode)
  (store-directory build-store-directory)
  (directory-parent build-directory-parent)
  (cores build-cores)
  (sandboxed? build-sandboxed?)
  (guix-program build-guix-program)
  (environment build-daemon-environment)
  (use-substitutes? build-use-substitutes?)
  (options build-options))

(define* (build-config #:key mode store-directory directory-parent cores sandboxed?
                       guix-program environment use-substitutes? options)
  "Return a build configuration with fields supplied by keyword."
  (build-config-positional mode store-directory directory-parent cores sandboxed?
                           guix-program environment use-substitutes? options))
