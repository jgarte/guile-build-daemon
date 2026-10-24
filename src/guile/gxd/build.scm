;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build)
  #:use-module (gxd prelude)
  #:use-module ((gxd build realization)
                #:select (realize-path! &builder-exit-error))
  #:use-module ((gxd store-path) #:select (store-path?))
  #:use-module ((guix remote-procedures) #:select (build-mode))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception with-exception-handler))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates))
  #:export (build-paths! &build-request-error build-request-error? build-request-error-path
                         build-request-error-cause))

(define-exception-type &build-request-error &error
  make-build-request-error build-request-error?
  (path build-request-error-path)
  (cause build-request-error-cause))

(define (call-with-build-error-handling path thunk)
  "Call THUNK, reporting builder exit errors as build request failures for PATH."
  (with-exception-handler
    (lambda (exception)
      (raise-exception (make-build-request-error path exception)))
    thunk
    #:unwind? #t
    #:unwind-for-type &builder-exit-error))

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
       (call-with-build-error-handling path
         (lambda ()
           (realize-path! db store-directory path build-directory-parent cores log!))))
     _)))
