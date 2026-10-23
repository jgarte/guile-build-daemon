;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build)
  #:use-module (gxd prelude)
  #:use-module ((gxd build realization) #:select (realize-path!))
  #:use-module ((gxd store-path) #:select (store-path?))
  #:use-module ((guix remote-procedures) #:select (build-mode))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates))
  #:export (build-paths!))

(define (build-paths! db store-directory paths mode build-directory-parent cores log!)
  "Realize PATHS in MODE using DB and STORE-DIRECTORY.
Use BUILD-DIRECTORY-PARENT for workspaces, advertise CORES to builders, and
deliver binary log chunks to LOG!.  The caller excludes concurrent GC."
  (unless (= mode (build-mode normal))
    (todo! "non-normal build modes" mode))

  (for-each
   (lambda (path)
     (cond
      ((not (store-path? store-directory path))
       (error "build request path is not in the store" path))
      ((string-contains path ".drv!")
       (todo! "derivation output selectors" path))
      ((not (string-suffix? ".drv" path))
       (todo! "realization of non-derivation roots" path))))
   paths)

  (chain paths
    (delete-duplicates _ string=?)
    (sort _ string<?)
    (for-each
     (lambda (path)
       (realize-path! db store-directory path build-directory-parent cores log!))
     _)))
