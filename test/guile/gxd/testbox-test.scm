;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd testbox-test)
  #:use-module ((ice-9 exceptions)
                #:select (exception-args
                          exception-kind
                          exception-message
                          make-exception-with-message))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd test-prelude)
                #:select (capture-exception
                          with-module-binding
                          with-module-bindings))
  #:use-module ((gxd testbox btrfs)
                #:select (delete-testbox-root!
                          require-testbox-base
                          snapshot-base!
                          testbox-root-path))
  #:use-module ((gxd testbox)
                #:select (make-testbox-manifest
                          start-testbox
                          start-testbox-process!
                          teardown-testbox!
                          testbox-manifest
                          testbox-pid1
                          testbox-process-pid
                          testbox-root
                          wait-testbox-process!))
  #:use-module (gxd prelude))

(define guile (readlink "/proc/self/exe"))

(define (namespace-id pid name)
  "Return the identifier of PID's NAME namespace, which two processes share
exactly when they are in the same one."
  (readlink (format #f "/proc/~a/ns/~a" pid name)))

(define (call-with-testbox proc)
  (let ((box (start-testbox (make-testbox-manifest))))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc box))
      (lambda () (teardown-testbox! box)))))

(define (role-exit-status box role expression)
  "Run EXPRESSION as ROLE in BOX and return the status it exited with.
A role process is exec-only with no channel back, so it reports a single number
by exiting with it, which limits what EXPRESSION can report to a byte."
  (status:exit-val
   (wait-testbox-process!
    (start-testbox-process! box role guile
                            (list "-c" (format #f "(exit ~s)" expression))))))

(define (reaped? pid)
  "Return #t when PID has been collected already.  Waiting on such a pid
fails with ECHILD, which is what distinguishes it from one still running."
  (with-exception-handler
      (lambda (exception)
        (match (cons (exception-kind exception) (exception-args exception))
          (('system-error _ _ _ (errno)) (= errno ECHILD))
          (_ #f)))
    (lambda ()
      (waitpid pid WNOHANG)
      #f)
    #:unwind? #t))

(define (alive? pid)
  "Return #t when PID can be signalled, and so has not been reaped."
  (with-exception-handler
      (lambda (_) #f)
    (lambda ()
      (kill pid 0)
      #t)
    #:unwind? #t))

(define-suite (testbox-tests)
  (test "boxes started together get a root each" ()
    ;; Concurrent boxes share the test process, so roots cannot use its pid.
    (let ((first (start-testbox (make-testbox-manifest))))
      (dynamic-wind
        (lambda () #t)
        (lambda ()
          (let ((second (start-testbox (make-testbox-manifest))))
            (dynamic-wind
              (lambda () #t)
              (lambda ()
                (is (not (string=? (testbox-root first)
                                   (testbox-root second))))
                (is (file-exists? (testbox-root first)))
                (is (file-exists? (testbox-root second))))
              (lambda () (teardown-testbox! second)))))
        (lambda () (teardown-testbox! first)))))

  (test "testbox enters fresh user, mount, and pid namespaces" ()
    (call-with-testbox
     (lambda (box)
       (define (fresh? name)
         (not (string=? (namespace-id (testbox-pid1 box) name)
                        (namespace-id (getpid) name))))

       (is (fresh? 'user))
       (is (fresh? 'mnt))
       (is (fresh? 'pid)))))

  (test "teardown preserves its first failure and root after a reap failure" ()
    (let* ((box (start-testbox (make-testbox-manifest)))
           (pid1 (testbox-pid1 box))
           (root (testbox-root box))
           (process (start-testbox-process! box 'daemon guile
                                            '("-c" "(sleep 10)")))
           (process-pid (testbox-process-pid process))
           (failing-send
            (lambda _
              (raise-exception
               (make-exception-with-message "expected teardown failure")))))

      (is (alive? process-pid))

      ;; Reap PID 1 early so a later step fails too, and the first failure has
      ;; something it could be displaced by.
      (kill pid1 SIGKILL)
      (waitpid pid1 0)

      (define captured
        (with-module-binding
         (resolve-module '(gxd isolation)) 'send failing-send
         (lambda ()
           (capture-exception (lambda () (teardown-testbox! box))))))

      (is (string=? "expected teardown failure" (exception-message captured)))
      (is (reaped? pid1))
      (is (reaped? process-pid))
      (is (file-exists? root))

      (delete-testbox-root! pid1)))

  (test "programs run as either declared role" ()
    (call-with-testbox
     (lambda (box)
       (define (declared role key)
         (get-in (testbox-manifest box) (list 'testbox/roles role key)))
       (define (report role expression)
         (role-exit-status box role expression))

       (is (= (declared 'daemon 'role/uid) (report 'daemon '(getuid))))
       (is (= (declared 'daemon 'role/gid) (report 'daemon '(getgid))))
       (is (= (declared 'user 'role/uid) (report 'user '(getuid))))
       (is (= (declared 'user 'role/gid) (report 'user '(getgid))))

       ;; A role must not keep the groups of whoever started the box.
       (is (= 0 (report 'daemon '(vector-length (getgroups)))))
       (is (= 0 (report 'user '(vector-length (getgroups))))))))

  (test "process wait status is stable" ()
    (call-with-testbox
     (lambda (box)
       (let ((process
              (start-testbox-process! box 'daemon guile
                                      '("-c" "(exit 7)"))))
         (is (= 7 (status:exit-val (wait-testbox-process! process))))
         (is (= 7 (status:exit-val (wait-testbox-process! process))))))))

  (test "startup retains the root when PID 1 cannot be reaped" ()
    (define expected (make-exception-with-message "expected startup failure"))
    (define child-pid #f)
    (define testbox-module (resolve-module '(gxd testbox)))
    (define waitpid (module-ref testbox-module 'waitpid))

    (define (failing-write-id-maps pid uid-ranges gid-ranges)
      (set! child-pid pid)
      (raise-exception expected))

    (define (failing-pid1-wait pid options)
      (if (and child-pid (= child-pid pid))
          (raise-exception
           (make-exception-with-message "expected reap failure"))
          (waitpid pid options)))

    (define (start)
      (capture-exception
       (lambda () (start-testbox (make-testbox-manifest)))))
    (define captured
      (with-module-bindings
       testbox-module
       `((write-id-map-ranges! . ,failing-write-id-maps)
         (waitpid . ,failing-pid1-wait))
       start))
    (define root (testbox-root-path child-pid))

    (is (eq? expected captured))
    (is (file-exists? root))

    (waitpid child-pid 0)
    (delete-testbox-root! child-pid))

  (test "startup collision preserves the stale root" ()
    (define root #f)
    (define child-pid #f)
    (define child-proc
      (module-ref (resolve-module '(gxd isolation)) 'child-proc))

    (define (child-proc-with-stale-root flags child)
      (let ((result (child-proc flags child)))
        (set! child-pid (car result))
        (set! root (snapshot-base! child-pid))
        result))

    (define captured
      (with-module-binding
       (resolve-module '(gxd isolation)) 'child-proc
       child-proc-with-stale-root
       (lambda ()
         (capture-exception
          (lambda () (start-testbox (make-testbox-manifest)))))))

    (is captured)
    (is (file-exists? root))

    (delete-testbox-root! child-pid))

  (test "startup failure releases PID 1 before propagating" ()
    (define expected (make-exception-with-message "expected mapping failure"))
    (define child-pid #f)
    (define child-was-alive? #f)
    (define testbox-module (resolve-module '(gxd testbox)))

    ;; Fail the first step after the child exists, so startup has something to
    ;; roll back.  Liveness is recorded here because by the time the assertions
    ;; run the child is expected to be gone.
    (define (failing-write-id-maps pid uid-ranges gid-ranges)
      (set! child-pid pid)
      (set! child-was-alive? (alive? pid))
      (raise-exception expected))

    (define (start)
      (capture-exception
       (lambda () (start-testbox (make-testbox-manifest)))))
    (define captured
      (with-module-bindings
       testbox-module
       `((write-id-map-ranges! . ,failing-write-id-maps))
       start))
    (define root (testbox-root-path child-pid))

    (is (eq? expected captured))
    (is (integer? child-pid))
    (is child-was-alive?)
    (is (reaped? child-pid))
    (is (not (file-exists? root)))))
