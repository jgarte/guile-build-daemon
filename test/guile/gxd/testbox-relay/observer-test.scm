;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay observer-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ice-9 exceptions) #:select (raise-exception with-exception-handler))
  #:use-module ((gxd testbox-relay observer)
                #:select (close-relay-input!
                          make-relay-observer
                          read-next-completed-connection!
                          observed-connection-id
                          observed-connection-observations
                          observed-connection-status
                          relay-observer-observed-connections))
  #:use-module ((gxd testbox-relay observation-protocol)
                #:select (make-observation-output write-accepted
                          write-data
                          write-terminated)
                #:prefix observation:))

(define (call-with-observer proc)
  "Call PROC with an observer and its relay output, then close both ports."
  (let* ((ports (socketpair AF_UNIX SOCK_STREAM 0))
         (input (car ports))
         (output (cdr ports))
         (observer (make-relay-observer input)))
    (define (close!)
      (false-if-exception (close-relay-input! observer))
      (false-if-exception (close-port output)))

    (define result
      (with-exception-handler
        (lambda (exception) (close!) (raise-exception exception))
        (lambda () (proc observer (observation:make-observation-output output)))
        #:unwind? #t))

    (close!)
    result))

(define (connection-facts connection)
  (list (observed-connection-id connection)
        (observed-connection-status connection)
        (observed-connection-observations connection)))

(define (observer-facts observer)
  (map connection-facts
       (relay-observer-observed-connections observer)))

(define (observed-history)
  "Return projections as two accepted connections complete out of order."
  (call-with-observer
   (lambda (observer output)
     (observation:write-accepted output 1)
     (observation:write-accepted output 2)
     (observation:write-data output 1 'client #vu8(11))
     (observation:write-data output 2 'client #vu8(21))
     (observation:write-data output 2 'daemon #vu8(22))
     (observation:write-terminated output 2)
     (define first-completed
       (read-next-completed-connection! observer (+ 2 (current-time))))

     (define state-after-first-completion (observer-facts observer))

     (observation:write-terminated output 1)
     (define next-completed
       (read-next-completed-connection! observer (+ 2 (current-time))))

     `((first-completed ,@(connection-facts first-completed))
       (state-after-first-completion ,@state-after-first-completion)
       (next-completed ,@(connection-facts next-completed))
       (final-state ,@(observer-facts observer))))))

(define-suite (observer-tests)
  (test "terminal connections retain chronological observations" ()
    (is (equal?
         '((first-completed
            2 complete ((client . #vu8(21))
                        (daemon . #vu8(22))))
           (state-after-first-completion
            (1 open ((client . #vu8(11))))
            (2 complete ((client . #vu8(21))
                         (daemon . #vu8(22)))))
           (next-completed
            1 complete ((client . #vu8(11))))
           (final-state
            (1 complete ((client . #vu8(11))))
            (2 complete ((client . #vu8(21))
                         (daemon . #vu8(22))))))
         (observed-history)))))
