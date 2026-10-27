;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build config)
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:export (build-config build-mode build-store-directory build-directory-parent build-cores build-sandboxed?))

(define-record-type <build-config>
  (build-config mode store-directory directory-parent cores sandboxed?)
  build-config?
  (mode build-mode)
  (store-directory build-store-directory)
  (directory-parent build-directory-parent)
  (cores build-cores)
  (sandboxed? build-sandboxed?))
