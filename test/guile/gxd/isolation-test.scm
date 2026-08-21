;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd isolation-test)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((ice-9 atomic)
                #:select (atomic-box-ref atomic-box-set! make-atomic-box))
  #:use-module ((guix build syscalls) #:select (mount))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((ice-9 rdelim) #:select (read-line read-string))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((srfi srfi-13) #:select (string-contains))

  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((gxd isolation) #:select (child-proc
                                          make-mounts-private!
                                          mount-source!
                                          pivot-into!
                                          read-current-id-map-ranges
                                          write-id-map-ranges!
                                          CLONE_NEWUSER
                                          CLONE_NEWNS
                                          CLONE_NEWPID))
  #:use-module ((gxd prelude)))

(define (slurp file)
  (seek file 0 SEEK_SET)
  (read-string file))

(define (call-with-child-proc flags child proc)
  "Call PROC with the pid and the parent-side send and receive procedures of a
CHILD process started with FLAGS, releasing the channel and reaping the child
afterwards."
  (match-let (((pid => <= disconnect!) (child-proc flags child)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc pid => <=))
      (lambda ()
        ;; Close the channel before waiting: a child left blocked on a receive
        ;; exits once its endpoint is gone, where waiting first would deadlock.
        (disconnect!)
        (waitpid pid)))))

(define (alive? pid)
  "Return #t when PID can be signalled, and so has not been reaped."
  (with-exception-handler
      (lambda (_) #f)
    (lambda ()
      (kill pid 0)
      #t)
    #:unwind? #t))

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
     (let-values (((uid-ranges gid-ranges) (read-current-id-map-ranges 2)))
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

;; Host visibility is not a useful observable: mounts created in a user
;; namespace cannot propagate back to the host.  Inspect mountinfo propagation
;; fields instead to distinguish inherited shared/slave mounts from private ones.
(define (propagating-mounts)
  "Return propagating mountinfo lines and the total mount count."
  ;; The optional fields encode propagation: `shared:N' sends mount events,
  ;; `master:N' receives them, and a line with neither is private.
  (call-with-input-file "/proc/self/mountinfo"
    (lambda (port)
      (let loop ((propagating '()) (total 0))
        (define line (read-line port))
        (cond ((eof-object? line) (values propagating total))
              ((or (string-contains line " shared:")
                   (string-contains line " master:"))
               (loop (cons line propagating) (+ total 1)))
              (else (loop propagating (+ total 1))))))))

(define (child-propagating-mounts private?)
  "Return the propagating and total mount counts from a fresh mount namespace.
Make its mounts private first when PRIVATE? is true."
  (call-with-child-proc
   (logior CLONE_NEWUSER CLONE_NEWNS SIGCHLD)
   (lambda (=> <=)
     (when private? (make-mounts-private!))
     (let-values (((propagating total) (propagating-mounts)))
       (=> 'counted (list (length propagating) total))))
   (lambda (_ => <=) (apply values (<= 'counted)))))

(define-suite (make-mounts-private-tests)
  (test "a fresh mount namespace still follows the mounts it came from" ()
    ;; Making mounts private is only worth doing because they do not start
    ;; that way; without this the test below would prove nothing.
    (let-values (((propagating total) (child-propagating-mounts #f)))
      (is (> propagating 0))
      (is (> total 0))))

  (test "no mount is left propagating" ()
    ;; Every mount, not just the root: the root alone goes private without
    ;; MS_REC, and its submounts would carry on propagating.
    (let-values (((propagating total) (child-propagating-mounts #t)))
      (is (= 0 propagating))
      (is (> total 0)))))

(define (call-with-root proc)
  "Call PROC with a root directory containing /proc and /only-here."
  (let ((root (mkdtemp "/tmp/pivot-into-test-XXXXXX")))
    (dynamic-wind
      (lambda ()
        (mkdir (string-append root "/proc") #o755)
        (mkdir (string-append root "/only-here")))
      (lambda () (proc root))
      (lambda ()
        (rmdir (string-append root "/proc"))
        (rmdir (string-append root "/only-here"))
        (rmdir root)))))

(define (pivoted-into root)
  "Return what a child in ROOT sees of it and of the tree it came from."
  (call-with-child-proc
   (logior CLONE_NEWUSER CLONE_NEWNS CLONE_NEWPID SIGCHLD)
   (lambda (=> <=)
     (make-mounts-private!)
     (pivot-into! root)
     (=> 'seen `((entries . ,(scandir "/"))
                 ;; The directory the root was made under, which the child can
                 ;; only reach if the tree it came from is still there.
                 (tmp? . ,(file-exists? "/tmp"))
                 (own-directory? . ,(file-exists? "/only-here")))))
   (lambda (_ => <=) (<= 'seen))))

(define (mounted-source-in-box root source)
  "Return whether a box in ROOT sees SOURCE's file and can write beside it."
  (call-with-child-proc
   (logior CLONE_NEWUSER CLONE_NEWNS CLONE_NEWPID SIGCHLD)
   (lambda (=> <=)
     ;; Wait for the parent to install the id maps.  Until it has, this
     ;; process has no id the kernel can represent, and creating anything on
     ;; a filesystem it mounts fails with EOVERFLOW.
     (<= 'ids-mapped)
     (make-mounts-private!)
     ;; A box's root is a filesystem of its own, and pivoting recursively
     ;; binds it; a plain directory would make the source's mount part of
     ;; whatever subtree that directory sits in.  A tmpfs here stands in for
     ;; the clone, and belongs to this namespace alone.
     (mount "tmpfs" root "tmpfs" 0)
     (mkdir (string-append root "/proc"))
     (mount-source! root source)
     (pivot-into! root)
     (=> 'seen
         `((file? . ,(file-exists? (string-append source "/file")))
           (wrote? . ,(catch #t
                        (lambda ()
                          (call-with-output-file (string-append source "/written")
                            (lambda (port) (display "no" port)))
                          #t)
                        (lambda _ #f))))))
   (lambda (child-pid => <=)
     (let-values (((uid-ranges gid-ranges) (read-current-id-map-ranges 2)))
       (write-id-map-ranges! child-pid uid-ranges gid-ranges))
     (=> 'ids-mapped)
     (<= 'seen))))

(define (call-with-source proc)
  "Call PROC with a directory standing in for the source tree, holding a file
a box can look for."
  (let ((source (mkdtemp "/tmp/mount-source-test-XXXXXX")))
    (dynamic-wind
      (lambda ()
        (call-with-output-file (string-append source "/file")
          (lambda (port) (display "from the host" port))))
      (lambda () (proc source))
      (lambda ()
        (delete-file (string-append source "/file"))
        (rmdir source)))))

(define-suite (mount-source-tests)
  (test "a box reads the source at the path it has outside, and cannot write it" ()
    (call-with-root
     (lambda (root)
       (call-with-source
        (lambda (source)
          (let ((seen (mounted-source-in-box root source)))
            (is (get seen 'file?))
            (is (not (get seen 'wrote?)))
            ;; The failed write must not have reached the host either.
            (is (not (file-exists? (string-append source "/written")))))))))))

(define-suite (pivot-into-tests)
  (test "a process that pivots is left in the root it was given" ()
    (call-with-root
     (lambda (root)
       (let ((seen (pivoted-into root)))
         (is (get seen 'own-directory?))
         ;; /tmp holds the root itself, so seeing it would mean the box is
         ;; still looking at the tree its root was made in.
         (is (not (get seen 'tmp?)))
         ;; Nothing of the old root is left to reach, not even the empty
         ;; directory it was pivoted under.
         (is (not (member ".old-root" (get seen 'entries)))))))))

(define-suite (write-id-maps-tests)
  (test "mapping exposes only the requested number of subordinate ids" ()
    (let-values (((uid-ranges gid-ranges) (read-current-id-map-ranges 2)))
      (match-let ((((_ _ _) (_ _ uid-count)) uid-ranges)
                  (((_ _ _) (_ _ gid-count)) gid-ranges))
        (is (= 2 uid-count))
        (is (= 2 gid-count)))))

  (test "setuid helpers map multiple ids" ()
    (is (equal? '((1 1) (2 2)) (map mapped-ids '(1 2))))))
