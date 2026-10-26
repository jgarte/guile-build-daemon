;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build process)
  #:use-module (gxd prelude)
  #:use-module ((gxd isolation)
                #:select (write-self-id-maps! CLONE_NEWUSER CLONE_NEWPID
                                              CLONE_NEWNS CLONE_NEWNET CLONE_NEWIPC CLONE_NEWUTS))
  #:use-module ((guix build syscalls) #:select (safe-clone))
  #:use-module ((ice-9 exceptions)
                #:select (with-exception-handler raise-exception
                                                 exception-kind exception-args))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((ice-9 match) #:select (match match-let))
  #:use-module ((rnrs bytevectors) #:select (u8-list->bytevector))
  #:use-module ((rnrs io ports) #:select (get-u8))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:export (call-with-builder-process builder-pid builder-output wait-builder!))

;; The parent creates a pipe before cloning.  The child sends both stdout and
;; stderr into that pipe; the callback reads their merged bytes via `builder-output'.
;;
;;   Child process                         Parent process
;;   stdout (fd 1) --\
;;                    >-- log pipe ------> builder-output
;;   stderr (fd 2) --/
;;
;; The child's stdin (fd 0) reads /dev/null, so reads return EOF.
;; Before exec, the child writes a blank line to stderr to report setup success.
;; The callback sees that line first, followed by the executable's output.
;; Read `builder-output' until EOF before calling `wait-builder!'.  Reading
;; frees pipe capacity while the builder writes; waiting first can deadlock.
;; EOF does not establish child exit: the builder may close its output and
;; continue running.
;; When the callback returns or raises, `call-with-builder-process' closes the
;; output port and kills/reaps the direct child unless already reaped.

(define-record-type <builder-process>
  (make-builder-process pid output status)
  builder-process?
  (pid builder-pid)
  (output builder-output)
  (status builder-status set-builder-status!))

(define (bad-descriptor? exception)
  (and (eq? 'system-error (exception-kind exception))
       (= EBADF (system-error-errno
                 (cons (exception-kind exception) (exception-args exception))))))

(define (mark-close-on-exec! fd)
  (with-exception-handler
    (lambda (exception)
      ;; The procfs directory descriptor may already be closed after enumeration.
      (unless (bad-descriptor? exception) (raise-exception exception)))
    (lambda () (fcntl fd F_SETFD (logior FD_CLOEXEC (fcntl fd F_GETFD))))
    #:unwind? #t))

(define (set-exec-descriptor-flags!)
  ;; Keep Guile's port owners valid until the kernel closes descriptors at exec.
  (for-each (lambda (name)
              (let ((fd (string->number name)))
                (when (and fd (> fd 2)) (mark-close-on-exec! fd))))
            (scandir "/proc/self/fd"))
  ;; Standard descriptors must survive exec, even if dup2 used the same source fd.
  (for-each (lambda (fd) (fcntl fd F_SETFD 0)) '(0 1 2)))

(define (redirect-builder-stdio! pipe-reader pipe-writer)
  ;; Only the parent reads the log pipe.
  (close-port pipe-reader)
  ;; dup2 replaces stdout/stderr with references to the pipe's write endpoint.
  (dup2 (fileno pipe-writer) 1)
  (dup2 (fileno pipe-writer) 2)
  (close-port pipe-writer)

  (let ((null (open-fdes "/dev/null" O_RDWR)))
    (dup2 null 0)
    (unless (= null 0) (close-fdes null))))

(define (environment-entry binding)
  (match binding
    ((name . value) (string-append name "=" value))))

(define (exec-builder builder arguments environment directory input output)
  (define error-port #f)
  (with-exception-handler
    (lambda (exception)
      (false-if-exception
       (when error-port
         (format error-port "builder setup/exec failed: ~s~%" exception)
         (force-output error-port)))
      (primitive-_exit 1))
    (lambda ()
      (redirect-builder-stdio! input output)
      (set! error-port (fdopen 2 "w"))

      (setsid)
      (chdir directory)
      (set-exec-descriptor-flags!)
      (sigaction SIGPIPE SIG_DFL)
      (environ (map environment-entry environment))

      ;; Native spawn reports setup success before attempting exec.
      (newline error-port)
      (force-output error-port)
      (apply execl builder (basename builder) arguments))
    #:unwind? #t))

(define namespace-clone-flags
  (logior SIGCHLD CLONE_NEWUSER CLONE_NEWPID CLONE_NEWNS CLONE_NEWNET CLONE_NEWIPC CLONE_NEWUTS))

;; Linux send flag: a closed map-barrier peer must raise, not terminate the daemon.
(define MSG_NOSIGNAL #x4000)

(define id-maps-ready 1)

(define* (start-builder builder arguments environment directory #:optional isolated?)
  (define child-control #f)
  (define parent-control #f)
  (define ports #f)
  (define input #f)
  (define output #f)
  (define pid #f)
  (with-exception-handler
    (lambda (exception)
      (when (and pid (> pid 0))
        (false-if-exception (kill (if isolated? pid (- pid)) SIGKILL))
        (false-if-exception (waitpid pid)))
      (when input (false-if-exception (close-port input)))
      (when output (false-if-exception (close-port output)))
      (when child-control (false-if-exception (close-port child-control)))
      (when parent-control (false-if-exception (close-port parent-control)))
      (raise-exception exception))
    (lambda ()
      (when isolated?
        (match-let (((child . parent) (socketpair PF_UNIX (logior SOCK_STREAM SOCK_CLOEXEC) 0)))
          (set! child-control child)
          (set! parent-control parent)))
      (set! ports (pipe))
      (set! input (car ports))
      (set! output (cdr ports))
      (flush-all-ports)
      (set! pid
            (safe-clone
             (if isolated? namespace-clone-flags SIGCHLD)
             (lambda ()
               (call-with-cleanup
                (lambda () (primitive-_exit 1))
                (lambda ()
                  (when child-control
                    (close-port parent-control)
                    (unless (eqv? id-maps-ready (get-u8 child-control))
                      (error "identity-map acknowledgement missing"))
                    (close-port child-control))
                  (exec-builder builder arguments environment directory input output))))
             (lambda (pid) pid)))
      (close-port output)
      (when parent-control
        (close-port child-control)
        (write-self-id-maps! pid 30001 30000)
        (send parent-control (u8-list->bytevector (list id-maps-ready)) MSG_NOSIGNAL)
        (close-port parent-control))
      (make-builder-process pid input #f))
    #:unwind? #t))

(define (wait-builder! process)
  "Reap PROCESS and return its raw wait status, retaining the result for later calls.
Drain `builder-output' before waiting to avoid blocking a writer on its log pipe."
  (or (builder-status process)
      (let ((status (cdr (waitpid (builder-pid process)))))
        (set-builder-status! process status)
        status)))

(define (release-builder! process)
  (call-with-cleanup
   (lambda () (close-port (builder-output process)))
   (lambda ()
     (unless (builder-status process)
       (kill (- (builder-pid process)) SIGKILL)
       (wait-builder! process)))))

(define* (call-with-builder-process builder arguments environment directory proc
                                    #:optional (isolated? #f))
  "Run BUILDER with ARGUMENTS, environment alist ENVIRONMENT and cwd DIRECTORY.
Call PROC with its process handle; return PROC's values.  On exit close its
output, kill its process group and reap the direct child unless already waited
through `wait-builder!'.  The caller owns DIRECTORY.
With ISOLATED?, launch as PID 1 in mapped rootless namespaces."
  (define process (start-builder builder arguments environment directory isolated?))

  (call-with-cleanup
   (lambda () (release-builder! process))
   (lambda () (proc process))))
