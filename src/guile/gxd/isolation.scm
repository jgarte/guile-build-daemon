(define-module (gxd isolation)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 exceptions)
  #:use-module ((guix build syscalls) #:select (safe-clone))
  #:use-module ((gxd prelude))
  #:export (child-proc))



(define* (display-id-msg* prefix id #:optional payload as)
  "Format and display message followed by newline"
  (display
   (if as
       (format #f "~a[~a by ~a] ~a~%" prefix id (or as "") (or payload ""))
       (format #f "~a[~a] ~a~%" prefix id (or payload "")))))

;; Two simple util functions to create sender and receiver message functions,
;; where messages get matched by ID, and optional `payload' can be carried.
(define* (send-id-msg* port #:key as)
  (lambda* (id #:optional payload #:key print)
    (when print (display-id-msg* "send " id payload as))
    (write (list id payload) port)
    ;; Since child-proc exits via privitive-_exit,
    ;; which doesn't do Guile unwind, which would flush the buffered messages,
    ;; written buffered messages would be lost.
    ;; To prevent this we're flushing the message right away.
    (force-output port)))

(define* (recv-id-msg* port #:key  as)
  (lambda* (id #:key print)
    (match-let (((in-id payload) (read port)))
      (when print (when print (display-id-msg* "recv " id payload as)))
      (if (eq? id in-id)
          payload
          (raise-exception
           (make-exception-with-message
            (format #f "message id mismatch; expected: ~a; actual: ~a" id in-id)))))))

;; example behavior
(comment
 (match-let (((child . parent) (socketpair PF_UNIX (logior SOCK_CLOEXEC SOCK_STREAM) 0)))
   (let ((=> (send-id-msg* parent #:as 'parent))
         (<= (recv-id-msg* child #:as 'child)))
     (=> 1 #:print #t)
     (=> 2 'some-payload #:print #t)
     (list (<= 1)
           ;; (<= 'not-a-2) ;; would throw, id mismatch
           (<= 2 #:print #t)))))

(define child-proc
  ;; "Takes a lambda, which is passed a bidirectional 'parent' socket, executes it in a forked process.
  ;;  Returns the PID of that process and a bidirectional channel to communicate with it."
  (case-lambda
    ;; SIGCHLD flag instructs kernel to send a SIGCHLD signal to the parent process when child exits
    ((proc) (child-proc SIGCHLD proc))
    ;; Useful flags for namespace child isolation:
    ;; CLONE_NEWPID - Process IDs
    ;; CLONE_NEWNET - Network
    ;; CLONE_NEWNS - Mount Points / File System
    ;; CLONE_NEWUTS - Hostnames
    ;; CLONE_NEWIPC - Inter-Process Communication
    ;; CLONE_NEWUSER - Users and Groups
    ((flags proc)
    (match-let (((child . parent) (socketpair PF_UNIX (logior SOCK_CLOEXEC SOCK_STREAM) 0)))
      ;; flushing ports, so child cannot flush entries that parent would himself
      (flush-all-ports)
      (let ((outer-pid
             (safe-clone
              flags
              (lambda ()
                (close-port parent)
                (with-exception-handler
                 (lambda (exn)
                   (backtrace)
                   (flush-all-ports)
                   (primitive-_exit 1))
                 (lambda ()
                   (proc (send-id-msg* child) (recv-id-msg* child))
                   (flush-all-ports)
                   (primitive-_exit 0))))
              (lambda (pid) pid))))
        (close-port child)
        (list outer-pid (send-id-msg* parent) (recv-id-msg* parent)))))))

(comment
 (match-let (((child-pid => <=) (child-proc (lambda (=> <=)
                                              (<= 1)
                                              (display "child doing some work")
                                              (sleep 2)
                                              (=> 2 "done")))))
   (=> 1)
   (<= 2)))
