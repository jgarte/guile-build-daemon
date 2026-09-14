;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd testbox-test)
  #:use-module ((ice-9 exceptions)
                #:select (exception-args
                          exception-kind
                          make-exception-with-message))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((guix store) #:select (direct-store-path))
  #:use-module (gxd test-prelude)
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
  #:use-module ((gxd testbox disk)
                #:select (delete-testbox-root!
                          snapshot-base!)))

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

(define (reap-test-child! pid)
  "Kill and reap PID if this test still owns it."
  (when pid
    (with-exception-handler
        (lambda (exception)
          (match (cons (exception-kind exception) (exception-args exception))
            (('system-error _ _ _ (errno))
             (unless (= errno ECHILD) (raise-exception exception)))
            (_ (raise-exception exception))))
      (lambda ()
        (match (waitpid pid WNOHANG)
          ((0 . _)
           (kill pid SIGKILL)
           (waitpid pid 0))
          (_ #t)))
      #:unwind? #t)))

(define (delete-testbox-root-if-present! pid root)
  "Delete ROOT when it exists and PID identifies its testbox."
  (when (and pid root (file-exists? root))
    (delete-testbox-root! pid)))

(define-suite (testbox-tests)
  (test "testbox enters fresh user, mount, and pid namespaces" ()
    (call-with-testbox
     (lambda (box)
       (define (fresh? name)
         (not (string=? (namespace-id (testbox-pid1 box) name)
                        (namespace-id (getpid) name))))

       (is (fresh? 'user))
       (is (fresh? 'mnt))
       (is (fresh? 'pid)))))

  (test "teardown releases resources after notification failure" ()
    (define expected (make-exception-with-message "expected teardown failure"))
    (define box (start-testbox (make-testbox-manifest)))
    (define pid1 (testbox-pid1 box))
    (define root (testbox-root box))
    (define process-pid #f)

    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (define process
          (start-testbox-process! box 'daemon guile '("-c" "(sleep 10)")))
        (set! process-pid (testbox-process-pid process))
        (define (failing-send . _)
          (raise-exception expected))

        (is (alive? pid1))
        (is (alive? process-pid))
        (is (file-exists? root))

        (define captured
          (with-module-binding
           (resolve-module '(gxd isolation)) 'send failing-send
           (lambda ()
             (capture-exception (lambda () (teardown-testbox! box))))))

        (is (eq? expected captured))
        (is (reaped? pid1))
        (is (reaped? process-pid))
        (is (not (file-exists? root))))
      (lambda ()
        (reap-test-child! pid1)
        (reap-test-child! process-pid)
        (delete-testbox-root-if-present! pid1 root))))

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

  (test "a program starts in the box's private root" ()
    (define host-only-item
      (direct-store-path (canonicalize-path (require-program "ares-suitbl"))))

    (is (file-exists? host-only-item))

    (define status
      (call-with-testbox
       (lambda (box)
         (role-exit-status
          box 'daemon
          `(if (and (string=? (getcwd) "/")
                    (not (file-exists? ,host-only-item)))
               0
               1)))))

    (is (= 0 status)))

  (test "gxd source is exposed read-only at its host path" ()
    (define source (canonicalize-path "src/guile/gxd/prelude.scm"))
    (define attempted
      (string-append (canonicalize-path "src") "/"
                     (symbol->string (gensym ".testbox-write-"))))

    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (is (file-exists? source))

        (define status
          (call-with-testbox
           (lambda (box)
             (role-exit-status
              box 'daemon
              `(begin
                 (use-modules (ice-9 exceptions))
                 (if (and (file-exists? ,source)
                          (with-exception-handler
                              (lambda (exception)
                                (= EROFS
                                   (system-error-errno
                                    (cons (exception-kind exception)
                                          (exception-args exception)))))
                            (lambda ()
                              (with-output-to-file ,attempted
                                (lambda () (display "written")))
                              #f)
                            #:unwind? #t))
                     0
                     1))))))

        (is (= 0 status))
        (is (not (file-exists? attempted))))
      (lambda ()
        (when (file-exists? attempted) (delete-file attempted)))))

  (test "process wait status is stable" ()
    (call-with-testbox
     (lambda (box)
       (let ((process
              (start-testbox-process! box 'daemon guile
                                      '("-c" "(exit 7)"))))
         (is (= 7 (status:exit-val (wait-testbox-process! process))))
         (is (= 7 (status:exit-val (wait-testbox-process! process))))))))

  (test "snapshot refusal preserves the existing root" ()
    (define snapshot! snapshot-base!)
    (define child-pid #f)
    (define child-was-alive? #f)
    (define root #f)
    (define sentinel #f)
    (define (refuse-snapshot pid1)
      (set! child-pid pid1)
      (set! child-was-alive? (alive? pid1))
      (set! root (snapshot! pid1))
      (set! sentinel (string-append root "/sentinel"))
      (with-output-to-file sentinel (lambda () (display "preserved")))
      (snapshot! pid1))

    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (is (throws-exception?
             (with-module-binding
              (resolve-module '(gxd testbox)) 'snapshot-base! refuse-snapshot
              (lambda () (start-testbox (make-testbox-manifest))))))
        (is child-was-alive?)
        (is (reaped? child-pid))
        (is (string=? "preserved" (slurp sentinel))))
      (lambda ()
        (reap-test-child! child-pid)
        (delete-testbox-root-if-present! child-pid root))))

  (test "filesystem setup failure releases the acquired root" ()
    (define snapshot! snapshot-base!)
    (define child-pid #f)
    (define root #f)
    (define (snapshot-with-blocked-proc pid1)
      (set! child-pid pid1)
      (set! root (snapshot! pid1))
      (with-output-to-file (string-append root "/proc") (lambda () #t))
      root)

    (dynamic-wind
      (lambda () #t)
      (lambda ()
        (is (throws-exception?
             (with-module-binding
              (resolve-module '(gxd testbox)) 'snapshot-base!
              snapshot-with-blocked-proc
              (lambda () (start-testbox (make-testbox-manifest))))))
        (is (reaped? child-pid))
        (is (not (file-exists? root))))
      (lambda ()
        (reap-test-child! child-pid)
        (delete-testbox-root-if-present! child-pid root)))))
