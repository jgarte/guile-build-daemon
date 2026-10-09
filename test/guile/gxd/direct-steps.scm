;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd direct-steps)
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((guix store)
                #:select (add-text-to-store close-connection open-connection valid-path?))
  #:use-module (gxd test-prelude)
  #:export (direct-steps-fixture))

(define (call-with-client endpoint proc)
  "Call PROC with a new connection to ENDPOINT; close it before returning."
  (let ((store (open-connection endpoint)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc store))
      (lambda () (close-connection store)))))

(define (paired-step! left right expression)
  "Execute EXPRESSION on fresh clients at LEFT and RIGHT within five seconds.
Close both clients and return their common result; raise on failure or mismatch."
  (define store-proc
    (match expression
      (('valid-path? (? string? path))
       (lambda (store) (valid-path? store path)))
      (('add-text-to-store (? string? name) (? string? text) . arguments)
       (lambda (store) (apply add-text-to-store store name text arguments)))
      (_ (error "unsupported direct step" expression))))

  (define results
    (call-with-process-deadline
     5
     (lambda ()
       (define left-result (call-with-client left store-proc))
       (define right-result (call-with-client right store-proc))
       (list left-result right-result))))

  (match results
    ((left-result right-result)
     (unless (equal? left-result right-result)
       (error "direct step responses differ" expression left-result right-result))
     left-result)))

(define (direct-steps-fixture ctx proceed)
  "Preserve CTX and add step!, accepting Guix client operations as data with the
store argument omitted, for example (valid-path? PATH).  Return the operation's
result if it agrees across both testboxes; raise otherwise."
  (let ((left (get ctx 'relay/left-endpoint))
        (right (get ctx 'relay/right-endpoint)))
    (unless (and (string? left) (string? right))
      (error "direct steps require two relay endpoints" left right))
    (proceed (acons 'step! (lambda (expression) (paired-step! left right expression))
                    ctx)
             (lambda () #t))))
