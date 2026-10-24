;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox snapshots)
  #:use-module ((gxd testbox) #:select (testbox-pid1 testbox-root))
  #:use-module ((gxd testbox disk) #:select (snapshot-root! delete-snapshot!))
  #:use-module (gxd test-prelude)
  #:use-module ((ice-9 exceptions) #:select (raise-exception))
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((srfi srfi-1) #:select (delete find))
  #:export (paired-snapshots-fixture))

(define (paired-snapshots-fixture ctx proceed)
  "Add `snapshot!' and `observe-snapshot!' to CTX.
The former returns fresh left/right root snapshot paths; the latter applies
a callback to each fresh snapshot and returns its common result, or raises.
Each call replaces the preceding snapshots.  Delete owned snapshots at teardown.
Call only after the operations whose effects are to be observed have finished."
  (let ((left (get ctx 'testbox/left))
        (right (get ctx 'testbox/right))
        (owned '()))
    (unless (and left right)
      (error "observation snapshots require two testboxes"))

    (define (delete-owned-snapshot! name)
      (capture-exception
       (lambda ()
         (delete-snapshot! name)
         (set! owned (delete name owned)))))

    (define (cleanup!)
      (and-let* ((failure
                  (chain owned
                    (map delete-owned-snapshot! _)
                    (find identity _))))
        (raise-exception failure)))

    (define (snapshot-box! box)
      (let* ((name (string-append (number->string (testbox-pid1 box)) "-snapshot"))
             (path (snapshot-root! (testbox-root box) name)))
        (set! owned (cons name owned))
        path))

    (define (snapshot!)
      (cleanup!)
      (let* ((left-path (snapshot-box! left))
             (right-path (snapshot-box! right)))
        (list left-path right-path)))

    (define (observe-snapshot! proc)
      (match-let (((left-path right-path) (snapshot!)))
        (let* ((left-result (proc left-path))
               (right-result (proc right-path)))
          (unless (equal? left-result right-result)
            (error "snapshot observations differ" left-result right-result))
          left-result)))

    (proceed (append `((snapshot! . ,snapshot!)
                       (observe-snapshot! . ,observe-snapshot!))
                     ctx)
             cleanup!)))
