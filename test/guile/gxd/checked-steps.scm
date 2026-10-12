;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd checked-steps)
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((srfi srfi-1) #:select (remove))
  #:use-module (gxd test-prelude)
  #:export (checked-steps-fixture))

(define (checked-steps-fixture ctx proceed)
  "Wrap CTX's step! with a check of its two completed connection captures.
Require step! and observe-bytes!.  Check unnamed calls and named #:terminal? #t
calls before returning; other named calls return without draining observations.
On mismatch raise with the expression, response and both captures.
Remove observe-bytes!, relay/left-observer and relay/right-observer downstream:
the wrapped step! owns observation consumption.  Preserve other context."
  (let ((step! (get ctx 'step!))
        (observe-bytes! (get ctx 'observe-bytes!)))
    (unless (and (procedure? step!) (procedure? observe-bytes!))
      (error "checked steps require step! and observe-bytes!"))
    (define* (checked-step! expression #:key connection (terminal? #f))
      (define response
        (step! expression #:connection connection #:terminal? terminal?))

      (when (or (not connection) terminal?)
        (match (observe-bytes!)
          ((left right)
           (unless (bytevector=? left right)
             (error "step responses agree but connection bytes differ"
                    expression response left right)))))
      response)

    (proceed
     (acons 'step! checked-step!
            (remove (lambda (entry)
                      (memq (car entry)
                            '(step! observe-bytes!
                                    relay/left-observer relay/right-observer)))
                    ctx))
     (lambda () #t))))
