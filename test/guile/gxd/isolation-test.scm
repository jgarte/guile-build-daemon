;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd isolation-test)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module (ice-9 exceptions)
  #:use-module ((ice-9 atomic) #:select (make-atomic-box atomic-box-ref atomic-box-set!))
  #:use-module (ice-9 rdelim)

  #:use-module (ares suitbl core)
  #:use-module (ares suitbl checks)
  #:use-module ((gxd isolation) #:select (child-proc
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

(define-suite (child-proc-tests)
  (test "message receival blocks process until message arrival" ()
    (let ((file (tmpfile))
          (content "content"))
      (call-with-child-proc
       SIGCHLD
       (lambda (=> <=)
         (<= 'go)
         (display content file)
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
