(define-module (gxd isolation)
  #:use-module ((ice-9 match) #:select (match-lambda match-let))
  #:use-module ((ice-9 exceptions) #:select (make-exception-with-message))
  #:use-module ((rnrs bytevectors)
                #:select (bytevector-copy!
                          bytevector-length
                          make-bytevector
                          string->utf8))
  #:use-module ((srfi srfi-1) #:select (append-map find))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((srfi srfi-197) #:select (chain))
  #:use-module ((gnu build accounts)
                #:select (read-subgid
                          read-subuid
                          subid-entry-count
                          subid-entry-name
                          subid-entry-start))
  #:use-module ((guix build utils) #:select (invoke mkdir-p))
  #:use-module ((guix build syscalls) #:select (mount
                                                pivot-root
                                                safe-clone
                                                umount
                                                MNT_DETACH
                                                MS_BIND
                                                MS_NODEV
                                                MS_NOEXEC
                                                MS_NOSUID
                                                MS_RDONLY
                                                MS_REC
                                                MS_REMOUNT
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
            make-mounts-private!
            bind-mount-read-only!
            pivot-into!
            read-current-id-facts
            read-current-id-map-ranges
            start-in-namespaces
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

(define (read-current-id-facts required-count)
  "Return the current UID, subordinate UID start, current GID, and subordinate
GID start.  Each start covers at least REQUIRED-COUNT contiguous ids."
  (let* ((user (passwd:name (getpwuid (getuid))))
         (uid-entry (subid-entry user (read-subuid) required-count))
         (gid-entry (subid-entry user (read-subgid) required-count)))
    (values (getuid) (subid-entry-start uid-entry)
            (getgid) (subid-entry-start gid-entry))))

(define (read-current-id-map-ranges required-count)
  "Return UID and GID map ranges covering REQUIRED-COUNT subordinate ids.
Each is a list of (INSIDE OUTSIDE COUNT) ranges mapping the current user to
root, then REQUIRED-COUNT ids drawn from the ranges configured for them."
  (let-values (((uid uid-start gid gid-start)
                (read-current-id-facts required-count)))
    (values `((0 ,uid 1) (1 ,uid-start ,required-count))
            `((0 ,gid 1) (1 ,gid-start ,required-count)))))

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

;; Linux MS_PRIVATE, from linux/mount.h.  The pinned Guix exports MS_BIND,
;; MS_REC and MNT_DETACH from (guix build syscalls), but not this one.
(define MS_PRIVATE (ash 1 18))

(define (make-mounts-private!)
  "Make / and every mount below it private to this mount namespace."
  ;; New mount namespaces inherit propagation groups.  MS_REC makes every
  ;; inherited mount private, not only /, so later host mounts cannot enter.
  (mount #f "/" #f (logior MS_REC MS_PRIVATE)))

(define (bind-mount-read-only! source target)
  "Bind-mount directory SOURCE read-only at TARGET."
  (mkdir-p target)
  (mount source target #f MS_BIND)
  ;; Bind mounts inherit flags; remount to add MS_RDONLY.  Preserve locked
  ;; MS_NOSUID and MS_NODEV, or the kernel rejects the remount with EPERM.
  (mount #f target #f
         (logior MS_BIND MS_REMOUNT MS_RDONLY MS_NOSUID MS_NODEV)))

(define (pivot-into! root)
  "Make ROOT this process's root, detach the previous root, and mount procfs
for the current PID namespace."
  (mkdir-p (string-append root "/proc"))

  ;; pivot_root takes a mount point, so bind ROOT onto itself.
  ;; MS_REC preserves its submounts.
  (mount root root #f (logior MS_BIND MS_REC))

  ;; Inherited procfs reports the PID namespace in which it was mounted.
  (mount "proc" (string-append root "/proc") "proc"
         (logior MS_NOSUID MS_NODEV MS_NOEXEC))

  (chdir root)
  (let ((old-root (mkdtemp ".old-root-XXXXXX")))
    (pivot-root "." old-root)
    (chdir "/")

    ;; Detaching is what puts the old root out of reach; until then the box
    ;; holds a handle on the tree it came from.
    (umount (string-append "/" old-root) MNT_DETACH)
    (rmdir (string-append "/" old-root))))

(define namespace-options
  '(("user" . "user")
    ("mount" . "mnt")
    ("pid" . "pid")))

(define (start-in-namespaces nsenter pid uid gid program arguments)
  "Start PROGRAM with ARGUMENTS in the user, mount and pid namespaces of PID.
UID and GID name the identity inside that user namespace, not on the host.
Return the pid of the process monitoring PROGRAM, whose wait status is
PROGRAM's own."
  (let ((command
         (append (list "nsenter")
                 (map (match-lambda
                        ((option . name)
                         (format #f "--~a=/proc/~a/ns/~a"
                                 option pid name)))
                      namespace-options)
                 (list (format #f "--setgid=~a" gid)
                       (format #f "--setuid=~a" uid)
                       program)
                 arguments)))
    (flush-all-ports)
    (safe-clone SIGCHLD
                (lambda ()
                  (with-exception-handler
                      (lambda (_) (primitive-_exit 127))
                    (lambda () (apply execl nsenter command))
                    #:unwind? #t))
                (lambda (monitor-pid) monitor-pid))))
