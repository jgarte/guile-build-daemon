;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build)
  #:use-module (gxd prelude)
  #:use-module ((gxd build config) #:select (build-store-directory (build-mode . config-build-mode)))
  #:use-module ((gxd build realization)
                #:select (realize-path! builder-exit-error?))
  #:use-module ((gxd build outputs)
                #:select (missing-output-error? output-permission-error?
                          flat-output-type-error? output-hash-mismatch?))
  #:use-module ((gxd database) #:select (invalid-reference? invalid-reference-path))
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
  "Call THUNK, reporting build failures for requested PATH."
  (with-exception-handler
    (lambda (exception)
      (if (or (builder-exit-error? exception)
              (missing-output-error? exception)
              (output-permission-error? exception)
              (flat-output-type-error? exception)
              (output-hash-mismatch? exception)
              (and (invalid-reference? exception)
                   (string=? path (invalid-reference-path exception))))
          (raise-exception (make-build-request-error path exception))
          (raise-exception exception)))
    thunk
    #:unwind? #t))

(define (build-paths! db paths config log!)
  "Realize PATHS using DB and CONFIG.
Deliver binary log chunks to LOG!.
The caller excludes concurrent GC."
  (unless (= (config-build-mode config) (build-mode normal))
    (todo! "non-normal build modes" (config-build-mode config)))

  (set! paths (delete-duplicates paths string=?))

  (for-each
   (lambda (path)
     (cond
      ((not (store-path? (build-store-directory config) path))
       (error "build request path is not in the store" path))
      ((string-contains path ".drv!")
       (todo! "derivation output selectors" path))
      ((not (string-suffix? ".drv" path))
       (todo! "realization of non-derivation roots" path))))
   paths)

  (chain paths
    (sort _ string<?)
    (for-each
     (lambda (path)
       (call-with-build-error-handling path
         (lambda ()
           (realize-path! db path config log!))))
     _)))
