;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd testbox)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((guix build syscalls)
                #:select (CLONE_NEWNS CLONE_NEWPID CLONE_NEWUSER))
  #:use-module ((gxd isolation)
                #:select (child-proc
                          make-mounts-private!
                          mount-source!
                          pivot-into!
                          read-current-id-map-ranges
                          start-in-namespaces
                          write-id-map-ranges!))
  #:use-module ((gxd testbox btrfs)
                #:select (delete-testbox-root!
                          require-testbox-base
                          snapshot-base!))
  #:use-module ((gxd test-prelude) #:select (capture-exception))
  #:use-module (gxd prelude)
  #:export (make-testbox-manifest
            start-testbox
            start-testbox-process!
            testbox-manifest
            testbox-pid1
            testbox-process-pid
            testbox-root
            teardown-testbox!
            wait-testbox-process!))

;; A box gets its own user, mount and pid namespaces.  It has no network
;; namespace yet, so it shares the host's.
(define namespace-flags (logior CLONE_NEWUSER CLONE_NEWNS CLONE_NEWPID))

(define roles
  '((daemon . ((role/uid . 1) (role/gid . 1)))
    (user . ((role/uid . 2) (role/gid . 2)))))

(define source-root
  (canonicalize-path
   (string-append (dirname (%search-load-path "gxd/testbox"))
                  "/../../..")))

(define-record-type <testbox-process>
  (make-testbox-process pid forget!)
  testbox-process?
  (pid testbox-process-pid)
  (forget! testbox-process-forget!)
  (status testbox-process-status set-testbox-process-status!))

(define-record-type <testbox>
  (make-testbox manifest pid1 send! disconnect! active? processes nsenter root)
  testbox?
  (manifest testbox-manifest)
  (pid1 testbox-pid1)
  (send! testbox-send!)
  (disconnect! testbox-disconnect!)
  (active? testbox-active? set-testbox-active?!)
  (processes testbox-processes set-testbox-processes!)
  (nsenter testbox-nsenter)
  (root testbox-root))

(define (testbox-init => <=)
  ;; ROOT arrives after the parent installs id maps; mounting without mapped
  ;; ids fails.
  (let ((root (<= 'root)))
    ;; The base is a store, so create the procfs mount point needed after pivot.
    (mkdir (string-append root "/proc"))
    (make-mounts-private!)
    (mount-source! root source-root)
    (pivot-into! root))
  ;; As PID 1, this process adopts orphaned descendants.  Explicitly ignoring
  ;; SIGCHLD tells Linux to discard their exit status and reap them
  ;; automatically, so adopted children cannot accumulate as zombies.
  (sigaction SIGCHLD SIG_IGN)
  (=> 'ready)
  (<= 'terminate))

(define (make-testbox-manifest)
  "Return the declarative roles available inside a testbox."
  `((testbox/roles . ,roles)))

(define (nsenter)
  (or (search-path (string-split (or (getenv "PATH") "") #\:) "nsenter")
      (error "unable to find nsenter")))

(define (release-start-child! child-pid disconnect!)
  "Attempt to release CHILD-PID and its channel; return whether it was reaped."
  (capture-exception disconnect!)
  (capture-exception (lambda () (kill child-pid SIGKILL)))
  (not (capture-exception (lambda () (waitpid child-pid 0)))))

(define (cleanup-child-start-failure! child-pid disconnect! exception)
  "Attempt to release CHILD-PID and its channel, then re-raise EXCEPTION."
  (release-start-child! child-pid disconnect!)
  (raise-exception exception))

(define (cleanup-root-start-failure! child-pid disconnect! exception)
  "Attempt to release CHILD-PID and its channel, deleting its root only when
the child is reaped, then re-raise EXCEPTION."
  (when (release-start-child! child-pid disconnect!)
    (capture-exception (lambda () (delete-testbox-root! child-pid))))
  (raise-exception exception))

(define (start-testbox manifest)
  "Start a testbox described by MANIFEST with a private base snapshot.
On failure, attempt to release acquired resources before re-raising, retaining
the root unless every owned process is reaped."
  (require-testbox-base)
  (match-let (((child-pid => <= disconnect!)
               (child-proc (logior namespace-flags SIGCHLD) testbox-init)))
    ;; PID 1 uniquely identifies the root acquired for this box.
    ;; Until the snapshot succeeds there is no root to release.
    (define root
      (with-exception-handler
          (lambda (exception)
            (cleanup-child-start-failure! child-pid disconnect! exception))
        (lambda () (snapshot-base! child-pid))
        #:unwind? #t))

    (with-exception-handler
        (lambda (exception)
          (cleanup-root-start-failure! child-pid disconnect! exception))
      (lambda ()
        ;; PID 1 mounts ROOT on receipt, so send it only after its id maps
        ;; exist.
        (let-values (((uid-ranges gid-ranges) (read-current-id-map-ranges 2)))
          (write-id-map-ranges! child-pid uid-ranges gid-ranges))
        (=> 'root root)
        ;; Do not return until PID 1 has installed its child-reaping policy.
        (<= 'ready)
        (make-testbox manifest child-pid => disconnect! #t '() (nsenter)
                      root))
      #:unwind? #t)))

(define (start-testbox-process! box role program arguments)
  "Start PROGRAM with ARGUMENTS as ROLE inside BOX."
  (unless (testbox-active? box)
    (error "testbox has been torn down"))
  (let ((ids (get-in (testbox-manifest box) (list 'testbox/roles role))))
    (unless ids
      (error "unknown testbox role" role))
    (letrec ((process
              (make-testbox-process
               (start-in-namespaces (testbox-nsenter box) (testbox-pid1 box)
                                    (get ids 'role/uid)
                                    (get ids 'role/gid)
                                    program arguments)
               (lambda ()
                 (set-testbox-processes!
                  box (delq process (testbox-processes box)))))))
      (set-testbox-processes! box (cons process (testbox-processes box)))
      process)))

(define (wait-testbox-process! process)
  "Wait for PROCESS and return its raw wait status."
  ;; Remember the status: the pid is reaped once, so a later call would
  ;; otherwise fail with ECHILD rather than report what the process did.
  (or (testbox-process-status process)
      (let ((status (cdr (waitpid (testbox-process-pid process) 0))))
        (set-testbox-process-status! process status)
        ((testbox-process-forget! process))
        status)))

(define (teardown-testbox! box)
  "Stop BOX, attempting every cleanup phase and raising the first failure.
Delete its root only after every owned process is reaped."
  (when (testbox-active? box)
    (set-testbox-active?! box #f)
    (let ((failure #f)
          (reaped? #t))
      (define (attempt thunk)
        (let ((raised (capture-exception thunk)))
          (unless failure (set! failure raised))
          (not raised)))

      (define (attempt-reap thunk)
        (unless (attempt thunk) (set! reaped? #f)))

      (attempt (lambda () ((testbox-send! box) 'terminate)))
      (attempt (lambda () ((testbox-disconnect! box))))
      (attempt-reap (lambda () (waitpid (testbox-pid1 box) 0)))
      (for-each (lambda (process)
                  (attempt-reap (lambda () (wait-testbox-process! process))))
                (testbox-processes box))
      ;; A retained root is safer and diagnosable; the existing-root guard
      ;; catches it if the pid is reused.
      (when reaped?
        (attempt
         (lambda () (delete-testbox-root! (testbox-pid1 box)))))

      (when failure (raise-exception failure)))))
