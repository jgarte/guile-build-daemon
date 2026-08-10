(define-module (gxd isolation)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 exceptions)
  #:use-module ((guix build syscalls) #:select (safe-clone))
  #:use-module ((gxd prelude))
  #:export (child-proc))



(define* (msg-display prefix id #:optional payload as)
  "Format and display message followed by newline"
  (display
   (if as
       (format #f "~a[~a by ~a] ~a~%" prefix id (or as "") (or payload ""))
       (format #f "~a[~a] ~a~%" prefix id (or payload "")))))

;; Two simple util functions to create sender and receiver message functions,
;; where messages get matched by ID, and optional `payload' can be carried.
(define* (msg-send port #:key as)
  (lambda* (id #:optional payload #:key print)
    (when print (msg-display "send " id payload as))
    (write (list id payload) port)
    ;; Since child-proc exits via privitive-_exit,
    ;; which doesn't do Guile unwind, which would flush the buffered messages,
    ;; written buffered messages would be lost.
    ;; To prevent this we're flushing the message right away.
    (force-output port)))

(define* (msg-recv port #:key as)
  (lambda* (id #:key print)
    (match-let (((in-id payload) (read port)))
      (when print (when print (msg-display "recv " id payload as)))
      (if (eq? id in-id)
          payload
          (raise-exception
           (make-exception-with-message
            (format #f "message id mismatch; expected: ~a; actual: ~a" id in-id)))))))

;; example behavior
(comment
 (match-let (((child . parent) (socketpair PF_UNIX (logior SOCK_CLOEXEC SOCK_STREAM) 0)))
   (let ((=> (msg-send parent #:as 'parent))
         (<= (msg-recv child #:as 'child)))
     (=> 1 #:print #t)
     (=> 2 'some-payload #:print #t)
     (list (<= 1)
           ;; (<= 'not-a-2) ;; would throw, id mismatch
           (<= 2 #:print #t)))))

(define* (child-proc flags proc)
  "Create a child process and a bidirectional message channel.

FLAGS are passed to `safe-clone'.  In this new child process, the PROC
is called with two procedures as arguments.  First is procedure to
send message to parent process, second is to receive message.  These
procedures are created by `msg-send' and `msg-recv' recpectively.

The 'send message procedure' takes ID of the message and optioan
PAYLOAD as well as optional key #:print, if you need to display the
messages set it to #t. The 'read message procedure' takes message ID
and optional #:print.

Return two values: the child PID and a parent runner.  The runner
calls a parent procedure with the parent-side send and receive
procedures.

The child and parent each close the unused end of a Unix stream
socket. The child exits with `primitive-_exit' status 0 after CHILD
returns.  If CHILD raises an exception, a backtrace is printed, ports
are flushed, and the child exits with status 1."
  (match-let (((child-port . parent-port)
               (socketpair PF_UNIX (logior SOCK_CLOEXEC SOCK_STREAM) 0)))
    ;; flushing ports, so child cannot flush entries that parent would himself
    (flush-all-ports)
    (let ((outer-pid
           (safe-clone
            flags
            (lambda ()
              (close-port parent-port)
              (with-exception-handler
                  (lambda (exn)
                    (backtrace)
                    (flush-all-ports)
                    (primitive-_exit 1))
                (lambda ()
                  (proc (msg-send child-port #:as 'child)
                        (msg-recv child-port #:as 'child))
                  (flush-all-ports)
                  (primitive-_exit 0))))
            (lambda (pid) pid))))
      (close-port child-port)
      (list outer-pid
            (msg-send parent-port #:as 'parent)
            (msg-recv parent-port #:as 'parent)))))

(comment
 (match-let (((child-pid => <=) (child-proc SIGCHLD
                                 (lambda (=> <=)
                                   (<= 1)
                                   (display "child doing some work")
                                   (sleep 2)
                                   (=> 2 "done")))))
   (=> 1)
   (<= 2)))
