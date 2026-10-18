;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox store-observations)
  #:use-module ((gxd testbox files-info-diff)
                #:select (scan-files-info diff-files-info format-files-info-diff))
  #:use-module (gxd test-prelude)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((srfi srfi-1) #:select (every))
  #:export (store-observations-fixture))

(define (store-observations-fixture ctx proceed)
  "Add `observe-store!' to CTX, using the preceding snapshot fixture.
Return the common structural inventory under /gnu/store, or raise with its diff.
Each call takes fresh snapshots; snapshot ownership stays with that fixture."
  (let ((snapshot! (get ctx 'snapshot!)))
    (unless snapshot!
      (error "store observations require the snapshot fixture"))

    (define (observe-store!)
      (match-let (((left-root right-root) (snapshot!)))
        (let* ((left (scan-files-info (string-append left-root "/gnu/store")))
               (right (scan-files-info (string-append right-root "/gnu/store")))
               (diff (diff-files-info left right)))
          (unless (every null? (map cdr diff))
            (error "store filesystem artifacts differ" (format-files-info-diff diff)))
          left)))

    (proceed (acons 'observe-store! observe-store! ctx) (lambda () #t))))
