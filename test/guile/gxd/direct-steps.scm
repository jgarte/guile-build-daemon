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
                                            set-build-options valid-path?))
  #:use-module ((ice-9 exceptions) #:select (raise-exception with-exception-handler))
  #:use-module (gxd test-prelude)
  #:export (call-with-client call-with-paired-clients paired-step! direct-steps-fixture))

(define (call-with-client endpoint proc)
  "Call PROC with a new connection to ENDPOINT; close it before returning."
  (let ((store (open-connection endpoint)))
    (call-with-cleanup
     (lambda () (close-connection store))
     (lambda () (proc store)))))

(define (call-with-paired-clients left-endpoint right-endpoint proc)
  "Call PROC with new clients for LEFT-ENDPOINT and RIGHT-ENDPOINT.
Close both clients before returning or propagating an exception."
  (call-with-client left-endpoint
    (lambda (left)
      (call-with-client right-endpoint
        (lambda (right) (proc left right))))))

(define (expression->procedure expression)
  (match expression
    (('valid-path? (? string? path))
     (lambda (store) (valid-path? store path)))
    (('add-text-to-store (? string? name) (? string? text) . arguments)
     (lambda (store) (apply add-text-to-store store name text arguments)))
    (('set-build-options . arguments)
     (lambda (store)
       (call-with-values
           (lambda () (apply set-build-options store arguments))
         list)))
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
Collect set-build-options' zero return values as an empty list.
Raise on other exceptions or differing outcomes.  With #:connection NAME,
reuse one named client pair until a #:terminal? #t call or fixture teardown.
Only one name can be open at a time; a call after closure opens a new pair.
Named calls execute in the caller without a per-operation deadline."
  (let ((left (get ctx 'relay/left-endpoint))
        (right (get ctx 'relay/right-endpoint))
        (name #f)
        (left-store #f)
        (right-store #f))
    (unless (and (string? left) (string? right))
      (error "direct steps require two relay endpoints" left right))
    (define (close-clients!)
      (define left-error
        (capture-exception
         (lambda () (when left-store (close-connection left-store)))))

      (define right-error
        (capture-exception
         (lambda () (when right-store (close-connection right-store)))))

      (set! left-store #f)
      (set! right-store #f)
      (set! name #f)
      (when (or left-error right-error)
        (raise-exception (or left-error right-error))))

    (define* (step! expression #:key connection (terminal? #f))
      (if (not connection)
          (deadline 5
            (call-with-client left
              (lambda (left-store)
                (call-with-client right
                  (lambda (right-store)
                    (paired-step! left-store right-store expression))))))
          (begin
            (unless (symbol? connection)
              (error "connection name must be a symbol" connection))
            (when (and name (not (eq? name connection)))
              (error "only one named connection is supported" name connection))
            (unless name
              (with-exception-handler
                (lambda (exception)
                  (capture-exception close-clients!)
                  (raise-exception exception))
                (lambda ()
                  (set! left-store (open-connection left))
                  (set! right-store (open-connection right)))
                #:unwind? #t)
              (set! name connection))
            (let ((outcome (paired-step! left-store right-store expression)))
              (when terminal? (close-clients!))
              outcome))))

    (proceed (acons 'step! step! ctx) close-clients!)))
