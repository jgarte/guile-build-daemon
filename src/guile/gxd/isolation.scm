(define-module (gxd isolation)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module (ice-9 textual-ports)
  #:use-module ((guix build syscalls) #:select (safe-clone))
  #:use-module ((gxd utils) #:select (comment))
  #:export (child-proc))


;; Two simple util functions to create sender and receiver message functions,
;; where messages get matched by ID, and optional `payload' can be carried.
(define (send-id-msg* chan)
  (lambda* (id #:optional payload)
    (write (list id payload) chan)
    ;; Since child-proc exits via privitive-_exit,
    ;; which doesn't do Guile unwind, which would flush the buffered messages,
    ;; written buffered messages would be lost.
    ;; To prevent this we're flushing the message right away.
    (force-output chan)))

(define (recv-id-msg* chan)
  (lambda (id)
    (match-let (((in-id payload) (read chan)))
      (if (eq? id in-id)
          payload
          (throw 'received-id-mismatch (format #f "expected id: ~a; actual id: ~a" id in-id))))))

;; example behavior
(comment
 (match-let (((child . parent) (socketpair PF_UNIX (logior SOCK_CLOEXEC SOCK_STREAM) 0)))
   (let ((=> (send-id-msg* parent))
         (<= (recv-id-msg* child)))
     (=> 1)
     (=> 2 'some-payload)
     (list (<= 1)
           ;; (<= 'not-a-2) ;; would throw, id mismatch
           (<= 2)))))

(define child-proc
  ;; "Takes a lambda, which is passed a bidirectional 'parent' socket, executes it in a forked process.
  ;;  Returns the PID of that process and a bidirectional channel to communicate with it."
  (case-lambda
   ((proc) (child-proc SIGCHLD proc))
   ((flags proc)
    (match-let (((child . parent) (socketpair PF_UNIX (logior SOCK_CLOEXEC SOCK_STREAM) 0)))
      ;; flushing out/err, so child cannot flush entries that parent would himself
      (force-output (current-output-port))
      (force-output (current-error-port))
      (let ((outer-pid
             (safe-clone
              flags
              (lambda ()
                (close-port parent)
                (catch #t
                  (lambda ()
                    (proc (send-id-msg* child) (recv-id-msg* child))
                    (primitive-_exit 0))
                  (lambda (key . args)
                    (display-backtrace (make-stack #t) (current-error-port))
                    (print-exception (current-error-port) #f key args)
                    (force-output (current-error-port))
                    (primitive-_exit 1))))
              (lambda (pid) pid))))

        (close-port child)
        (list outer-pid (send-id-msg* parent) (recv-id-msg* parent)))))))
