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
                          read-current-id-map-ranges
                          write-id-map-ranges!))
  #:use-module ((gxd test-prelude) #:select (capture-exception))
  #:use-module (gxd prelude)
  #:export (make-testbox-manifest
            start-testbox
            testbox-manifest
            testbox-pid1
            teardown-testbox!))

;; A box gets its own user, mount and pid namespaces.  It has no network
;; namespace yet, so it shares the host's.
(define namespace-flags (logior CLONE_NEWUSER CLONE_NEWNS CLONE_NEWPID))

(define roles
  '((daemon . ((role/uid . 1) (role/gid . 1)))
    (user . ((role/uid . 2) (role/gid . 2)))))

(define-record-type <testbox>
  (make-testbox manifest pid1 send! disconnect! active?)
  testbox?
  (manifest testbox-manifest)
  (pid1 testbox-pid1)
  (send! testbox-send!)
  (disconnect! testbox-disconnect!)
  (active? testbox-active? set-testbox-active?!))

(define (testbox-init => <=)
  ;; As PID 1, this process adopts orphaned descendants.  Explicitly ignoring
  ;; SIGCHLD tells Linux to discard their exit status and reap them
  ;; automatically, so adopted children cannot accumulate as zombies.
  (sigaction SIGCHLD SIG_IGN)
  (=> 'ready)
  (<= 'terminate))

(define (make-testbox-manifest)
  "Return the declarative roles available inside a testbox."
  `((testbox/roles . ,roles)))

(define (cleanup-start-failure! child-pid disconnect! exception)
  "Release CHILD-PID and its channel, then re-raise EXCEPTION.
Each step is attempted even if an earlier one failed, so one unusable handle
cannot strand the rest.  Their own failures are discarded: EXCEPTION is what
stopped startup, and says more than a complaint about a broken handle."
  (capture-exception disconnect!)
  (capture-exception (lambda () (kill child-pid SIGKILL)))
  (capture-exception (lambda () (waitpid child-pid 0)))
  (raise-exception exception))

(define (start-testbox manifest)
  "Start an isolated testbox described by MANIFEST."
  (match-let (((child-pid => <= disconnect!)
               (child-proc (logior namespace-flags SIGCHLD) testbox-init)))
    (with-exception-handler
        (lambda (exception)
          (cleanup-start-failure! child-pid disconnect! exception))
      (lambda ()
        (let-values (((uid-ranges gid-ranges) (read-current-id-map-ranges 2)))
          (write-id-map-ranges! child-pid uid-ranges gid-ranges))
        ;; Do not return until PID 1 has installed its child-reaping policy.
        (<= 'ready)
        (make-testbox manifest child-pid => disconnect! #t))
      #:unwind? #t)))

(define (teardown-testbox! box)
  "Stop BOX, releasing the channel and process it owns.
Raise the first failure encountered, once every step has been attempted: the
failure that stopped the box is more informative than one caused by the
half-released state it left behind."
  (when (testbox-active? box)
    (set-testbox-active?! box #f)
    (let ((failure #f))
      (define (attempt thunk)
        (let ((raised (capture-exception thunk)))
          (unless failure (set! failure raised))))

      (attempt (lambda () ((testbox-send! box) 'terminate)))
      (attempt (lambda () ((testbox-disconnect! box))))
      (attempt (lambda () (waitpid (testbox-pid1 box) 0)))

      (when failure (raise-exception failure)))))
