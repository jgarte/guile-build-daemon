(define-module (gxd isolation)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 exceptions)
  #:use-module ((rnrs bytevectors)
                #:select (bytevector-copy!
                          bytevector-length
                          make-bytevector
                          string->utf8))
  #:use-module ((srfi srfi-1) #:select (append-map find))
  #:use-module ((srfi srfi-197) #:select (chain))
  #:use-module ((gnu build accounts)
                #:select (read-subgid
                          read-subuid
                          subid-entry-count
                          subid-entry-name
                          subid-entry-start))
  #:use-module ((guix build utils) #:select (invoke))
  #:use-module ((guix build syscalls) #:select (safe-clone
                                                ;; Linux clone flags, from linux/sched.h
                                                ;; for namespace isolation:
                                                CLONE_NEWPID  ;; Process IDs
                                                CLONE_NEWNET  ;; Network
                                                CLONE_NEWNS  ;; Mount Points / File System
                                                CLONE_NEWUTS  ;; Hostnames
                                                CLONE_NEWIPC  ;; Inter-Process Communication
                                                CLONE_NEWUSER  ;; Users and Groups
                                                ))
  #:re-export (CLONE_NEWPID
               CLONE_NEWNET
               CLONE_NEWNS
               CLONE_NEWUTS
               CLONE_NEWIPC
               CLONE_NEWUSER)
  #:use-module ((gxd prelude))
  #:export (child-proc
            read-current-id-map-ranges
            write-id-map-ranges!))



(define* (msg-display prefix id #:optional payload as)
  "Format and display message followed by newline"
  (display
   (if as
       (format #f "~a[~a by ~a] ~a~%" prefix id (or as "") (or payload ""))
       (format #f "~a[~a] ~a~%" prefix id (or payload "")))))

;; Two simple util functions to create sender and receiver message functions,
;; where messages get matched by ID, and optional `payload' can be carried.

;; Linux MSG_NOSIGNAL, from sys/socket.h.  Without it a send to a closed peer
;; raises SIGPIPE, whose default action terminates the process before Scheme
;; can handle anything; with it the send reports EPIPE instead.
(define MSG_NOSIGNAL #x4000)

(define (send-all port bytes)
  "Send all of BYTES over PORT, which may accept them a few at a time."
  (let loop ((pending bytes))
    (let ((sent (send port pending MSG_NOSIGNAL)))
      (unless (= sent (bytevector-length pending))
        (let* ((length (- (bytevector-length pending) sent))
               (rest (make-bytevector length)))
          (bytevector-copy! pending sent rest 0 length)
          (loop rest))))))

(define* (msg-send port #:key as)
  (lambda* (id #:optional payload #:key print)
    (when print (msg-display "send " id payload as))
    (chain (list id payload)
           (object->string _)
           (string->utf8 _)
           (send-all port _))))

(define* (msg-recv port #:key as)
  (set-port-encoding! port "UTF-8")
  (lambda* (id #:key print)
    (match-let (((in-id payload) (read port)))
      (when print (when print (msg-display "recv " id payload as)))
      (if (eq? id in-id)
          payload
          (raise-exception
           (make-exception-with-message
            (format #f "message id mismatch; expected: ~a; actual: ~a" id in-id)))))))

(define (make-disconnect port)
  (let ((disconnected? #f))
    (lambda ()
      (unless disconnected?
        (set! disconnected? #t)
        (close-port port)))))

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

(define* (child-proc flags child)
  "Create a child process and a bidirectional message channel.

FLAGS is a bitwise integer that specifies which resources the child process
shares with the parent.  You can use `logior' (bitwise OR) to combine individual
flags (e.g., flags for `clone' syscall listed in linux/sched.h)

In this new child process, the CHILD procedure is called with two
arguments. First argument is a procedure to send a message to parent
process ('send'), second argument is to receive a message ('recv').  These
procedures are created by `msg-send' and `msg-recv' respectively.

The 'send' procedure takes ID of the message and optional PAYLOAD as well as
optional key #:print which you can set to #t if you need to display the
messages. The 'recv' procedure takes message ID and the optional #:print.

Return the child PID, the parent-side `send' and `recv' procedures, and an
idempotent procedure that closes the parent endpoint."
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
                  (child (msg-send child-port #:as 'child)
                         (msg-recv child-port #:as 'child))
                  (flush-all-ports)
                  (primitive-_exit 0))))
            (lambda (pid) pid))))
      (close-port child-port)
      (list outer-pid
            (msg-send parent-port #:as 'parent)
            (msg-recv parent-port #:as 'parent)
            (make-disconnect parent-port)))))

(comment
 (match-let (((child-pid => <= disconnect!)
              (child-proc SIGCHLD
                          (lambda (=> <=)
                            (<= 1)
                            (display "child doing some work")
                            (sleep 2)
                            (=> 2 "done")))))
   (=> 1)
   (<= 2)
   (disconnect!)))

(define (subid-entry user entries required-count)
  "Return the first of ENTRIES granting USER at least REQUIRED-COUNT
subordinate ids, or raise an error when USER has no range that large."
  (or (find (lambda (entry)
              (and (string=? user (subid-entry-name entry))
                   (>= (subid-entry-count entry) required-count)))
            entries)
      (error "no suitable subordinate id range" user required-count)))

(define (read-current-id-map-ranges required-count)
  "Return UID and GID map ranges covering REQUIRED-COUNT subordinate ids.
Each is a list of (INSIDE OUTSIDE COUNT) ranges mapping the current user to
root, then REQUIRED-COUNT ids drawn from the ranges configured for them."
  (let* ((user (passwd:name (getpwuid (getuid))))
         (uid-entry (subid-entry user (read-subuid) required-count))
         (gid-entry (subid-entry user (read-subgid) required-count)))
    (values `((0 ,(getuid) 1)
              (1 ,(subid-entry-start uid-entry)
                 ,required-count))
            `((0 ,(getgid) 1)
              (1 ,(subid-entry-start gid-entry)
                 ,required-count)))))

(define (id-map-arguments ranges)
  (append-map (lambda (range) (map number->string range)) ranges))

(define (id-map-helper name)
  (or (chain '("/run/privileged/bin" "/usr/bin")
             (map (lambda (directory)
                    (string-append directory "/" name)) _)
             (find (lambda (path) (access? path X_OK)) _))
      (error "id map helper not found" name)))

(define (write-id-map-ranges helper pid ranges)
  (apply invoke
         (id-map-helper helper)
         (number->string pid)
         (id-map-arguments ranges)))

(define (write-id-map-ranges! pid uid-ranges gid-ranges)
  "Install UID-RANGES and GID-RANGES in the user namespace of PID."
  ;; These helpers are setuid-root, which is what allows a map with more than
  ;; the single self-mapping an unprivileged process could write itself.  They
  ;; need setgroups to remain allowed, so do not deny it before calling them.
  (write-id-map-ranges "newuidmap" pid uid-ranges)
  (write-id-map-ranges "newgidmap" pid gid-ranges))
