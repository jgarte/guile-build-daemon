;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd testbox)
  #:use-module ((gnu build accounts)
                #:select (group-entry
                          password-entry
                          write-group
                          write-passwd))
  #:use-module ((ice-9 match) #:select (match-let match-lambda))
  #:use-module ((srfi srfi-1) #:select (append-map delete-duplicates iota))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:use-module ((guix build utils) #:select (executable-file? mkdir-p))
  #:use-module ((guix build syscalls)
                #:select (mount
                          restart-on-EINTR
                          CLONE_NEWNS
                          CLONE_NEWPID
                          CLONE_NEWUSER))
  #:use-module ((gxd isolation)
                #:select (bind-mount!
                          bind-mount-read-only!
                          child-proc
                          mount-tmpfs!
                          make-mounts-private!
                          pivot-into!
                          read-current-id-facts
                          start-in-namespaces
                          write-id-map-ranges!))
  #:use-module (gxd test-prelude)
  #:use-module ((gxd testbox disk)
                #:select (delete-testbox-root! snapshot-base!))
  #:export (call-with-testbox
            make-testbox-manifest
            paired-daemon-testboxes-fixture
            start-nix-daemon!
            start-gxd!
            start-guix-command!
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

(define daemon-modes
  '((rootless
     (testbox/roles
      . ((daemon . ((role/uid . 1)
                    (role/gid . 1)))
         (user . ((role/uid . 2)
                  (role/gid . 2))))))
    (rootful
     (testbox/roles
      . ((daemon . ((role/uid . 0)
                    (role/gid . 0)))
         (user . ((role/uid . 2)
                  (role/gid . 2)))
         (gxdbuild01 . ((role/uid . 3)
                        (role/gid . 3)))))
     (testbox/groups
      . ((gxdbuild . ((group/gid . 3)
                      (group/members . (gxdbuild01)))))))))

(define-record-type <testbox-process>
  (make-testbox-process pid forget!)
  testbox-process?
  (pid testbox-process-pid)
  (forget! testbox-process-forget!)
  (status testbox-process-status set-testbox-process-status!))

(define-record-type <testbox>
  (make-testbox manifest root pid1 send! disconnect! active? processes nsenter)
  testbox?
  (manifest testbox-manifest)
  (root testbox-root)
  (pid1 testbox-pid1)
  (send! testbox-send!)
  (disconnect! testbox-disconnect!)
  (active? testbox-active? set-testbox-active?!)
  (processes testbox-processes set-testbox-processes!)
  (nsenter testbox-nsenter))

(define (mode-configuration daemon-mode)
  "Return the testbox configuration selected by DAEMON-MODE."
  (or (assq-ref daemon-modes daemon-mode)
      (error "unknown daemon mode" daemon-mode)))

(define (role->password-entry role)
  (password-entry
   (name (symbol->string (car role)))
   (uid (get (cdr role) 'role/uid))
   (gid (get (cdr role) 'role/gid))
   (directory "/")))

(define (group->entry group)
  (group-entry
   (name (symbol->string (car group)))
   (gid (get (cdr group) 'group/gid))
   (members (map symbol->string (get (cdr group) 'group/members)))))

(define (group-member-roles roles groups)
  "Return the distinct ROLES named as members of GROUPS.
Raise an error when a group names an unknown role."
  (define (group-member-names group)
    (get (cdr group) 'group/members))

  (define (require-role name)
    (or (assq name roles) (error "unknown group member" name)))

  (chain groups
    (append-map group-member-names _)
    (delete-duplicates _)
    (map require-role _)))

(define (install-group-accounts! root manifest)
  "Install MANIFEST's named groups and member accounts beneath ROOT."
  (define groups (get manifest 'testbox/groups))

  (when (pair? groups)
    (let ((etc (string-append root "/etc"))
          (roles (get manifest 'testbox/roles)))
      (mkdir-p etc)
      (chain groups
        (group-member-roles roles _)
        (map role->password-entry _)
        (write-passwd _ (string-append etc "/passwd")))
      (chain groups
        (map group->entry _)
        (write-group _ (string-append etc "/group"))))))

(define (mount-testbox-dev-tmpfs! root)
  "Mount a fresh device directory beneath ROOT."
  (mount-tmpfs! (string-append root "/dev")))

(define (mount-testbox-devices! root)
  "Bind nixd's minimal device set beneath ROOT/dev."
  (for-each
   (lambda (device)
     (when (file-exists? device)
       (bind-mount! device (string-append root device))))
   '("/dev/full"
     "/dev/kvm"
     "/dev/null"
     "/dev/random"
     "/dev/tty"
     "/dev/urandom"
     "/dev/zero")))

(define (mount-testbox-dev-shm! root)
  "Mount fresh shared memory beneath ROOT/dev."
  (mount-tmpfs! (string-append root "/dev/shm") #:mode #o1777))

(define (mount-testbox-devpts! root)
  "Mount private pseudo-terminals beneath ROOT/dev when available."
  (when (file-exists? "/dev/pts/ptmx")
    (let ((pts (string-append root "/dev/pts")))
      (mkdir-p pts)
      (mount "none" pts "devpts" 0 "newinstance,mode=0620")
      (chmod (string-append pts "/ptmx") #o666)
      (symlink "/dev/pts/ptmx" (string-append root "/dev/ptmx")))))

(define (install-testbox-dev-fd-links! root)
  "Install standard file-descriptor links beneath ROOT/dev."
  (for-each
   (lambda (name target)
     (symlink target (string-append root "/dev/" name)))
   '("fd" "stdin" "stdout" "stderr")
   '("/proc/self/fd" "/proc/self/fd/0" "/proc/self/fd/1" "/proc/self/fd/2")))

(define (mount-testbox-sources! root manifest)
  "Bind the sources listed in MANIFEST into ROOT read-only."
  (for-each
   (match-lambda
     ((_ . source)
      (bind-mount-read-only! source (string-append root source))))
   (get manifest 'testbox/sources)))

(define (prepare-build-log-directory! root manifest)
  "Create the build log directory beneath ROOT, owned by MANIFEST's daemon role."
  (let ((log-directory (string-append root "/var/log/guix"))
        (daemon (get-in manifest '(testbox/roles daemon))))
    (mkdir-p log-directory)
    (chown log-directory (get daemon 'role/uid) (get daemon 'role/gid))))

(define (prepare-substitute-acl! root)
  "Install the public test cache ACL beneath disposable ROOT before launch."
  (let ((directory (string-append root "/etc/guix")))
    (mkdir-p directory)
    (call-with-resource "substitutes/acl"
                        (lambda (port) (spit (string-append directory "/acl") (slurp port))))
    (chmod (string-append directory "/acl") #o644)))

(define (testbox-init => <=)
  "Prepare the root, enter it, report readiness, then await exit."
  ;; As PID 1, this process adopts orphaned descendants.  Explicitly ignoring
  ;; SIGCHLD tells Linux to discard their exit status and reap them
  ;; automatically, so adopted children cannot accumulate as zombies.
  (sigaction SIGCHLD SIG_IGN)
  (with-exception-handler
    (lambda (exception)
      (capture-exception
       (lambda () (=> 'ready (object->string exception))))
      (raise-exception exception))
    (lambda ()
      (match-let (((root manifest) (<= 'setup)))
        (make-mounts-private!)
        (mount-testbox-dev-tmpfs! root)
        (mount-testbox-devices! root)
        (mount-testbox-dev-shm! root)
        (mount-testbox-devpts! root)
        (install-testbox-dev-fd-links! root)
        (install-group-accounts! root manifest)
        (prepare-substitute-acl! root)
        (prepare-build-log-directory! root manifest)
        (mount-testbox-sources! root manifest)
        (pivot-into! root))
      (=> 'ready #f))
    #:unwind? #t)
  (<= 'terminate))

(define (make-testbox-manifest daemon-mode)
  "Return DAEMON-MODE's roles, groups and canonical harness sources."
  `((testbox/daemon-mode . ,daemon-mode)
    (testbox/sources
     . ((gxd . ,(canonicalize-path "src"))
        (relay . ,(canonicalize-path "test/guile/gxd/testbox-relay"))))
    ,@(mode-configuration daemon-mode)))

(define (role-id-map-ranges manifest id-key current-id subordinate-start)
  "Return MANIFEST's ID-KEY ranges, mapping CURRENT-ID to the daemon and the
remaining identities consecutively from SUBORDINATE-START."
  (define roles (get manifest 'testbox/roles))
  (define daemon (get roles 'daemon))
  (define identities
    (map cdr (delq (assq 'daemon roles) roles)))

  (cons `(,(get daemon id-key) ,current-id 1)
        (map (lambda (identity outside)
               `(,(get identity id-key) ,outside 1))
             identities
             (iota (length identities) subordinate-start))))

(define (cleanup-start-failure! child-pid disconnect! root exception)
  "Release CHILD-PID and its channel, then re-raise EXCEPTION.
Delete ROOT only after CHILD-PID has been reaped.  ROOT is #f when startup did
not acquire one."
  (capture-exception (lambda () (disconnect!)))
  (capture-exception (lambda () (kill child-pid SIGKILL)))
  (restart-on-EINTR (waitpid child-pid 0))
  (when root
    (capture-exception (lambda () (delete-testbox-root! child-pid))))
  (raise-exception exception))

(define (start-testbox manifest)
  "Start an isolated testbox described by MANIFEST."
  (let ((nsenter-path (require-program "nsenter"))
        (root #f))
    (match-let (((child-pid => <= disconnect!)
                 (child-proc (logior namespace-flags SIGCHLD) testbox-init)))
      (with-exception-handler
        (lambda (exception)
          (cleanup-start-failure! child-pid disconnect! root exception))
        (lambda ()
          ;; Install PID 1's ID mappings before filesystem setup.
          (let* ((roles (get manifest 'testbox/roles))
                 (required-count (1- (length roles))))
            (define-values (uid uid-start gid gid-start)
              (read-current-id-facts required-count))

            (write-id-map-ranges!
             child-pid
             (role-id-map-ranges manifest 'role/uid uid uid-start)
             (role-id-map-ranges manifest 'role/gid gid gid-start)))

          ;; Acquire a private root and tell PID 1 to enter it.
          (set! root (snapshot-base! child-pid))
          (=> 'setup (list root manifest))

          ;; Wait for filesystem setup before returning the live box.
          (and-let* ((setup-failure (<= 'ready)))
            (error (format #f "testbox setup failed: ~a" setup-failure)))

          (make-testbox manifest root child-pid => disconnect! #t '()
                        nsenter-path))
        #:unwind? #t))))

(define* (start-testbox-process! box role program arguments
                                 #:key (environment '()))
  "Start PROGRAM with ARGUMENTS as ROLE inside BOX.
ENVIRONMENT overrides inherited string name/value pairs in the child only."
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
                                    program arguments #:environment environment)
               (lambda ()
                 (set-testbox-processes!
                  box (delq process (testbox-processes box)))))))
      (set-testbox-processes! box (cons process (testbox-processes box)))
      process)))

(define (start-nix-daemon! box)
  "Start the selected Guix daemon mode inside BOX and return its process."
  (let* ((program (canonicalize-path (require-program "guix-daemon")))
         (arguments
          (case (get (testbox-manifest box) 'testbox/daemon-mode)
            ((rootless) '("--build-users-group="))
            ((rootful) '("--build-users-group=gxdbuild"))))
         (in-box-program (string-append (testbox-root box) program)))
    (unless (and (executable-file? in-box-program)
                 (eq? 'regular (stat:type (stat in-box-program))))
      (error "Guix daemon is not executable in testbox" program))
    (start-testbox-process! box 'daemon program arguments)))

(define (start-gxd! box)
  "Start gxd inside BOX as the daemon role and return its process."
  (let* ((guix (canonicalize-path (require-program "guix")))
         (source (get-in (testbox-manifest box) '(testbox/sources gxd))))
    (start-testbox-process! box 'daemon guix
                            (list "repl" "-L" (string-append source "/guile")
                                  "--" (string-append source "/main.scm"))
                            #:environment `(("GUIX" . ,guix)))))

(define (start-guix-command! box role arguments)
  "Start Guix with ARGUMENTS as ROLE against BOX's daemon; return its process.
Standard output and error are inherited.  BOX owns the process."
  (let ((guix (canonicalize-path (require-program "guix"))))
    (start-testbox-process!
     box role guix arguments
     #:environment '(("GUIX_DAEMON_SOCKET" . "/var/guix/daemon-socket/socket")))))

(define (call-with-testbox manifest proc)
  "Call PROC with a box described by MANIFEST, tearing it down before return."
  (let ((box (start-testbox manifest)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (proc box))
      (lambda () (teardown-testbox! box)))))

(define (resolve-daemon-launcher daemon-kind)
  "Return DAEMON-KIND's implemented launcher, or raise an error."
  (case daemon-kind
    ((nixd) start-nix-daemon!)
    ((gxd) start-gxd!)
    (else (error "unknown daemon" daemon-kind))))

(define (paired-daemon-testboxes-fixture daemon-mode
                                         left-daemon-kind right-daemon-kind)
  "Return a fixture that starts LEFT-DAEMON-KIND and RIGHT-DAEMON-KIND in
separately scoped DAEMON-MODE boxes.  Preserve context and add the boxes under
`testbox/left' and `testbox/right'."
  (let ((left-launcher (resolve-daemon-launcher left-daemon-kind))
        (right-launcher (resolve-daemon-launcher right-daemon-kind)))
    (lambda (ctx proceed)
      (define manifest (make-testbox-manifest daemon-mode))

      (call-with-testbox
       manifest
       (lambda (left-box)
         (left-launcher left-box)

         (call-with-testbox
          manifest
          (lambda (right-box)
            (right-launcher right-box)

            (proceed
             `((testbox/left . ,left-box)
               (testbox/right . ,right-box)
               ,@ctx)
             (lambda () #t)))))))))

(define* (wait-testbox-process! process #:key deadline)
  "Wait for PROCESS and return its raw wait status.
If absolute DEADLINE is supplied, raise when it expires before completion.
On timeout, PROCESS remains owned by its box; the caller must end that scope."
  ;; Remember the status: the pid is reaped once, so a later call would
  ;; otherwise fail with ECHILD rather than report what the process did.
  (or (testbox-process-status process)
      (match-let (((pid . status)
                   (restart-on-EINTR
                    (waitpid (testbox-process-pid process)
                             (if deadline WNOHANG 0)))))
        ;; WNOHANG returns PID 0 while running, the child's pid when reaped.
        (if (zero? pid)
            (begin
              (when (>= (current-time) deadline)
                (error "testbox process deadline exceeded"
                       (testbox-process-pid process)))
              (usleep 10000)
              (wait-testbox-process! process #:deadline deadline))
            (begin
              (set-testbox-process-status! process status)
              ((testbox-process-forget! process))
              status)))))

(define (teardown-testbox! box)
  "Stop BOX, reap every process it owns, and delete its root.
Re-raise a channel failure after releasing the remaining resources."
  (when (testbox-active? box)
    (set-testbox-active?! box #f)
    (let ((failure #f))
      (define (attempt thunk)
        (let ((raised (capture-exception thunk)))
          (unless failure (set! failure raised))))

      (attempt (lambda () ((testbox-send! box) 'terminate)))
      (attempt (lambda () ((testbox-disconnect! box))))
      (restart-on-EINTR (waitpid (testbox-pid1 box) 0))
      ;; PID 1's exit kills namespace members.  These are their outer nsenter
      ;; monitors in the host PID namespace, which still need reaping.
      (for-each wait-testbox-process! (testbox-processes box))
      (attempt (lambda () (delete-testbox-root! (testbox-pid1 box))))

      (when failure (raise-exception failure)))))
