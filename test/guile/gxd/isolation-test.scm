;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd isolation-test)
  #:use-module ((ice-9 match) #:select (match match-let))
  #:use-module ((ice-9 atomic)
                #:select (atomic-box-ref atomic-box-set! make-atomic-box))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((srfi srfi-1) #:select (any))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((srfi srfi-13)
                #:select (string-prefix? string-tokenize))

  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((guix build utils) #:select (delete-file-recursively))
  #:use-module ((guix build syscalls) #:select (mount MS_SHARED))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((gxd isolation) #:select (child-proc
                                          make-mounts-private!
                                          mount-tmpfs!
                                          bind-mount!
                                          bind-mount-read-only!
                                          pivot-into!
                                          read-current-id-facts
                                          write-id-map-ranges!
                                          CLONE_NEWUSER
                                          CLONE_NEWNS
                                          CLONE_NEWPID))
  #:use-module (gxd test-prelude))

(define (call-with-child-proc flags child proc)
  "Call PROC with the pid and the parent-side send and receive procedures of a
CHILD process started with FLAGS, releasing the channel and reaping the child
afterwards."
  (match-let (((pid => <= disconnect!) (child-proc flags child)))
    (call-with-cleanup
     (lambda ()
       ;; Close the channel before waiting: a child left blocked on a receive
       ;; exits once its endpoint is gone, where waiting first would deadlock.
       (disconnect!)
       (waitpid pid))
     (lambda () (proc pid => <=)))))

(define (alive? pid)
  "Return #t when PID can be signalled, and so has not been reaped."
  (with-exception-handler
    (lambda (_) #f)
    (lambda ()
      (kill pid 0)
      #t)
    #:unwind? #t))

(define (current-root-id-map-ranges required-count)
  "Map the current UID and GID to root, followed by REQUIRED-COUNT subordinate
IDs."
  (let-values (((uid uid-start gid gid-start)
                (read-current-id-facts required-count)))
    (values `((0 ,uid 1) (1 ,uid-start ,required-count))
            `((0 ,gid 1) (1 ,gid-start ,required-count)))))

(define-suite (call-with-child-proc-tests)
  (test "a scope reaps the child it started" ()
    (define child-pid #f)
    (define alive-inside? #f)

    ;; Liveness is recorded inside the scope because by the time the assertions
    ;; run the child is expected to be gone.
    (call-with-child-proc
     SIGCHLD
     (lambda (=> <=) (<= 'exit))
     (lambda (pid => <=)
       (set! child-pid pid)
       (set! alive-inside? (alive? pid))
       (=> 'exit)))

    (is alive-inside?)
    (is (not (alive? child-pid))))

  (test "a scope releases a child still waiting to be spoken to" ()
    ;; The scope must close the channel before waiting: this child blocks on a
    ;; message the body never sends, and only its endpoint closing ends it.
    (call-with-child-proc
     SIGCHLD
     (lambda (=> <=)
       (=> 'ready "waiting")
       (<= 'never-sent))
     (lambda (_ => <=)
       (is (string=? "waiting" (<= 'ready)))))))

(define (mapped-ids id)
  "Return the uid and gid a child sees after switching to ID inside its map."
  (call-with-child-proc
   (logior CLONE_NEWUSER SIGCHLD)
   (lambda (=> <=)
     (<= 'ids-mapped)
     (setgid id)
     (setuid id)
     (=> 'ids (list (getuid) (getgid))))
   (lambda (child-pid => <=)
     (let-values (((uid-ranges gid-ranges) (current-root-id-map-ranges 2)))
       (write-id-map-ranges! child-pid uid-ranges gid-ranges))
     (=> 'ids-mapped)
     (<= 'ids))))

(define-suite (child-proc-tests)
  (test "messages preserve non-ASCII text under the C locale" ()
    (let ((locale (setlocale LC_ALL)))
      (dynamic-wind
        (lambda () (setlocale LC_ALL "C"))
        (lambda ()
          (call-with-child-proc
           SIGCHLD
           (lambda (=> _) (=> 'text "é"))
           (lambda (_ => <=)
             (is (string=? "é" (<= 'text))))))
        (lambda () (setlocale LC_ALL locale)))))

  (test "sending to an exited peer raises instead of killing this process" ()
    (match-let (((pid => <= disconnect!)
                 (child-proc SIGCHLD (lambda (=> _) (=> 'ready)))))
      (<= 'ready)
      ;; Wait for the child so its endpoint is certainly closed before sending.
      (waitpid pid)
      (is (throws-exception? (=> 'unreachable)))
      (disconnect!)))

  (test "message receival blocks process until message arrival" ()
    (let ((file (tmpfile))
          (content "content"))
      (call-with-child-proc
       SIGCHLD
       (lambda (=> <=)
         (<= 'go)
         (display content file)
         (force-output file)
         (=> 'done))
       (lambda (_ => <=)
         (is (string=? "" (slurp file)))
         (=> 'go)
         (<= 'done)
         (is (string=? content (slurp file)))))))

  (test "when expecting message with one ID and get with another - throws" ()
    (call-with-child-proc
     SIGCHLD
     (lambda (=> _) (=> 1))
     (lambda (_ => <=)
       (is (throws-exception? (<= 'not-1))))))

  (test "atomic-boxes are also isolated; child's mutation of the val isn't seen by parent" ()
    (let ((box (make-atomic-box 0)))
      (call-with-child-proc
       SIGCHLD
       (lambda (=> _)
         (atomic-box-set! box 1)
         (=> 'done))
       (lambda (_ => <=)
         (<= 'done)
         (is (eq? (atomic-box-ref box) 0))))))

  (test "shared resources are CoW; child can't mutate parent's and vice-versa" ()
    (define *box #f) ;; shared res
    (call-with-child-proc
     SIGCHLD
     (lambda (=> <=)
       (=> 'child-alive)
       (<= 'mutate!)
       (set! *box #t)
       (=> 'mutated *box)
       (<= 'parent-mutated)
       (=> 'child-value *box))
     (lambda (_ => <=)
       (<= 'child-alive) ;; blocks on 'child-alive
       (=> 'mutate!)
       (is (eq? (<= 'mutated) #t)) ;; child mutated its own version of *box (CoW)
       (is (eq? *box #f)) ;; parent's version is intact
       (set! *box 1)
       (=> 'parent-mutated)
       (is (eq? (<= 'child-value) #t)))))

  (test "clone into new user, mount and pid namespaces" ()
    (call-with-child-proc
     (logior CLONE_NEWUSER  ;; Users and Groups
             CLONE_NEWNS  ;; Mount Points / File System
             CLONE_NEWPID  ;; Process IDs
             SIGCHLD  ;; signal on child exit
             )
     (lambda (=> <=)
       (=> 'ns/mnt (readlink "/proc/self/ns/mnt"))
       (=> 'ns/pid (readlink "/proc/self/ns/pid"))
       (=> 'ns/user (readlink "/proc/self/ns/user")))
     (lambda (_ => <=)
       (is (not (string=? (<= 'ns/mnt) (readlink "/proc/self/ns/mnt"))))
       (is (not (string=? (<= 'ns/pid) (readlink "/proc/self/ns/pid"))))
       (is (not (string=? (<= 'ns/user) (readlink "/proc/self/ns/user"))))))))

(define (mount-propagation path)
  "Return PATH's mount propagation state as `shared', `slave', `shared+slave',
`unbindable', or `private', or #f when PATH has no mountinfo entry."
  (define (line->mount-propagation line)
    (match (string-tokenize line)
      ((_ _ _ _ mount-point _ optional ... "-" _ _ _)
       (and (string=? path mount-point)
            (let ((shared?
                   (any (lambda (field) (string-prefix? "shared:" field))
                        optional))
                  (slave?
                   (any (lambda (field)
                          (or (string-prefix? "master:" field)
                              (string-prefix? "propagate_from:" field)))
                        optional)))
              (cond ((and shared? slave?) 'shared+slave)
                    (shared? 'shared)
                    (slave? 'slave)
                    ((member "unbindable" optional) 'unbindable)
                    (else 'private)))))
      (_ #f)))
  (chain "/proc/self/mountinfo"
    (slurp _)
    (string-split _ #\newline)
    (any line->mount-propagation _)))

(define-suite (make-mounts-private-tests)
  (test "an inherited shared submount is made private" ()
    (call-with-child-proc
     (logior CLONE_NEWUSER CLONE_NEWNS SIGCHLD)
     (lambda (=> <=)
       (mount #f "/proc" #f MS_SHARED)
       (=> 'before (mount-propagation "/proc"))
       (make-mounts-private!)
       (=> 'after (mount-propagation "/proc")))
     (lambda (_ => <=)
       (is (memq (<= 'before) '(shared shared+slave)))
       (is (eq? 'private (<= 'after)))))))

(define (call-with-root entries proc)
  "Call PROC with a root directory containing directories named by ENTRIES."
  (let ((root (mkdtemp "/tmp/pivot-into-test-XXXXXX")))
    (dynamic-wind
      (lambda ()
        (for-each (lambda (entry)
                    (mkdir (string-append root "/" entry)))
                  entries))
      (lambda () (proc root))
      (lambda ()
        (delete-file-recursively root)))))

(define (observe-pivoted-root root)
  "Return the entries and PID visible after pivoting into ROOT."
  (call-with-child-proc
   (logior CLONE_NEWUSER CLONE_NEWNS CLONE_NEWPID SIGCHLD)
   (lambda (=> <=)
     (make-mounts-private!)
     (pivot-into! root)
     (=> 'observed
         `((entries . ,(scandir
                        "/"
                        (lambda (entry) (not (member entry '("." ".."))))))
           (pid . ,(readlink "/proc/self")))))
   (lambda (_ => <=) (<= 'observed))))

(define (observe-read-only-bind-mount source target)
  "Return the source content and whether TARGET accepts a write after mounting."
  (call-with-child-proc
   (logior CLONE_NEWUSER CLONE_NEWNS SIGCHLD)
   (lambda (=> <=)
     (<= 'ids-mapped)
     (make-mounts-private!)
     (bind-mount-read-only! source target)
     (=> 'observed
         `((content . ,(slurp (string-append target "/file")))
           (writable? . ,(not (throws-exception?
                               (spit (string-append target "/written")
                                     "written")))))))
   (lambda (child-pid => <=)
     (let-values (((uid-ranges gid-ranges) (current-root-id-map-ranges 1)))
       (write-id-map-ranges! child-pid uid-ranges gid-ranges))
     (=> 'ids-mapped)
     (<= 'observed))))

(define (observe-tmpfs target)
  "Return whether TARGET is a fresh writable tmpfs."
  (call-with-child-proc
   (logior CLONE_NEWUSER CLONE_NEWNS SIGCHLD)
   (lambda (=> <=)
     (<= 'ids-mapped)
     (make-mounts-private!)
     (mount-tmpfs! target)
     (spit (string-append target "/written") "written")
     (=> 'observed
         `((fresh? . ,(not (file-exists? (string-append target "/present"))))
           (content . ,(slurp (string-append target "/written"))))))
   (lambda (child-pid => <=)
     (let-values (((uid-ranges gid-ranges) (current-root-id-map-ranges 1)))
       (write-id-map-ranges! child-pid uid-ranges gid-ranges))
     (=> 'ids-mapped)
     (<= 'observed))))

(define-suite (mount-tmpfs-tests)
  (test "a tmpfs hides old contents and accepts writes" ()
    (call-with-temporary-directory
     (lambda (target)
       (spit (string-append target "/present") "present")
       (let ((observed (observe-tmpfs target)))
         (is (get observed 'fresh?))
         (is (string=? "written" (get observed 'content))))))))

(define (observe-writing-a-file-in-bind-mount source target file content)
  "Return alist of whether TARGET accepts writing a FILE with CONTENT after mounting (key 'writabe?) and SOURCE have the same FILE with the same CONTENT (key 'same-content?)."
  (call-with-child-proc
   (logior CLONE_NEWUSER CLONE_NEWNS SIGCHLD)
   (lambda (=> <=)
     (<= 'ids-mapped)
     (make-mounts-private!)
     (bind-mount! source target)
     (=> 'file-writing
         (not (throws-exception?
               (spit (string-append target "/" file) content)))))
   (lambda (child-pid => <=)
     (let-values (((uid-ranges gid-ranges) (current-root-id-map-ranges 1)))
       (write-id-map-ranges! child-pid uid-ranges gid-ranges))
     (=> 'ids-mapped)
     `((writable? . ,(<= 'file-writing))
       (same-content? . ,(string=? content (slurp (string-append source "/" file))))))))

(define-suite (bind-mount-tests)
  (test "source contents are exposed writable at the target" ()
    (call-with-temporary-directory
     (lambda (directory)
       (let* ((file "some-file")
              (content "some content")
              (source (string-append directory "/source"))
              (target (string-append directory "/target"))
              (observation
               (begin (mkdir source)
                      (observe-writing-a-file-in-bind-mount source target file content))))
         (is (get observation 'writable?))
         (is (get observation 'same-content?))
         ;; same as above 
         (is (string=? content (slurp (string-append source "/" file)))))))))

(define-suite (bind-mount-read-only-tests)
  (test "source contents are exposed read-only at the target" ()
    (define content "source content")
    (define observed
      (call-with-temporary-directory
       (lambda (directory)
         (let ((source (string-append directory "/source"))
               (target (string-append directory "/target")))
           (mkdir source)
           (spit (string-append source "/file") content)
           (observe-read-only-bind-mount source target)))))

    (is (string=? content (get observed 'content)))
    (is (not (get observed 'writable?)))))

(define-suite (pivot-into-tests)
  (test "a pivoted process sees its new root and PID namespace through procfs" ()
    (define observed
      (call-with-root '(".old-root" "only-here") observe-pivoted-root))

    (is (equal? '(".old-root" "only-here" "proc")
                (get observed 'entries)))
    (is (string=? "1" (get observed 'pid)))))

(define-suite (read-current-id-facts-tests)
  (test "current uid and gid are reported" ()
    (define-values (uid uid-start gid gid-start) (read-current-id-facts 2))

    (is (= (getuid) uid))
    (is (= (getgid) gid))))

(define-suite (write-id-maps-tests)
  (test "setuid helpers map multiple ids" ()
    (is (equal? '((1 1) (2 2)) (map mapped-ids '(1 2))))))
