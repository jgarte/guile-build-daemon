;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd direct-steps)
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((guix store)
                #:select (add-text-to-store close-connection open-connection
                                            &store-protocol-error store-protocol-error-message
                                            store-protocol-error-status
                                            valid-path?))
  #:use-module ((ice-9 exceptions) #:select (with-exception-handler))
  #:use-module (gxd test-prelude)
  #:export (direct-steps-fixture))

(define (call-with-client endpoint proc)
  "Call PROC with a new connection to ENDPOINT; close it before returning."
  (let ((store (open-connection endpoint)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc store))
      (lambda () (close-connection store)))))

(define (expression->procedure expression)
  (match expression
    (('valid-path? (? string? path))
     (lambda (store) (valid-path? store path)))
    (('add-text-to-store (? string? name) (? string? text) . arguments)
     (lambda (store) (apply add-text-to-store store name text arguments)))
    (_ (error "unsupported direct step" expression))))

(define (call-with-protocol-outcome proc store)
  "Return PROC's result on STORE or its protocol error as type/message/status data.
Propagate other exceptions."
  (with-exception-handler
    (lambda (exception)
      `((error/type . store-protocol-error)
        (error/message . ,(store-protocol-error-message exception))
        (error/status . ,(store-protocol-error-status exception))))
    (lambda () (proc store))
    #:unwind? #t
    #:unwind-for-type &store-protocol-error))

(define (common-outcome expression left-result right-result)
  (unless (equal? left-result right-result)
    (error "direct step responses differ" expression left-result right-result))
  left-result)

(define (paired-step! left right expression)
  "Execute EXPRESSION on open clients LEFT and RIGHT; return their common outcome.
Raise on other exceptions or differing outcomes.  The caller owns both clients."
  (let* ((proc (expression->procedure expression))
         (left-result (call-with-protocol-outcome proc left))
         (right-result (call-with-protocol-outcome proc right)))
    (common-outcome expression left-result right-result)))

(define (direct-steps-fixture ctx proceed)
  "Preserve CTX and add step!, accepting client operations as data with the
store argument omitted, for example (valid-path? PATH).  Return the operation's
result or protocol-error type/message/status data if equal across both boxes.
Raise on other exceptions or differing outcomes."
  (let ((left (get ctx 'relay/left-endpoint))
        (right (get ctx 'relay/right-endpoint)))
    (unless (and (string? left) (string? right))
      (error "direct steps require two relay endpoints" left right))
    (define (step! expression)
      (call-with-process-deadline
       5
       (lambda ()
         (call-with-client left
           (lambda (left-store)
             (call-with-client right
               (lambda (right-store)
                 (paired-step! left-store right-store expression))))))))

    (proceed (acons 'step! step! ctx)
             (lambda () #t))))
