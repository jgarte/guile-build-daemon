;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd git-server)
  #:use-module (gxd prelude)
  #:use-module ((gxd isolation) #:select (child-proc))
  #:use-module ((ice-9 match) #:select (match-let))
  #:export (call-with-git-server))

(define (open-listener)
  (define listener (socket AF_INET (logior SOCK_STREAM SOCK_CLOEXEC) 0))
  (bind listener AF_INET INADDR_LOOPBACK 0)
  (listen listener 16)
  listener)

(define (serve-client git repository listener client)
  "Replace this worker with GIT serving REPOSITORY over CLIENT's input and output.
Close LISTENER; keep stderr for diagnostics."
  (close-port listener)
  (dup2 (fileno client) 0)
  (dup2 (fileno client) 1)
  (close-port client)
  (execl git "git" "daemon" "--inetd" "--export-all" "--strict-paths"
         "--log-destination=stderr" "--init-timeout=10" "--timeout=10"
         (string-append "--base-path=" repository)
         "--" (string-append repository "/.git")))

(define (call-with-git-server git repository proc)
  "Call PROC with a loopback Git URL for the existing REPOSITORY, using GIT.
Serve connections serially.  On return or exception, terminate the server and
its service process group, reap the server, and preserve PROC's values."
  (match-let (((pid => <= disconnect!)
               (child-proc
                SIGCHLD
                (lambda (=> _)
                  (setsid)
                  (=> 'group-ready)
                  (define listener (open-listener))
                  (=> 'port (sockaddr:port (getsockname listener)))
                  (while #t
                         (let ((client (car (accept listener))))
                           (match-let (((worker-pid _=> _<= disconnect-worker!)
                                        (child-proc SIGCHLD
                                                    (lambda (_=> _<=)
                                                      (serve-client git repository listener client)))))
                             (close-port client)
                             (disconnect-worker!)
                             (waitpid worker-pid))))))))
    (define group-ready? #f)
    (call-with-cleanup
     disconnect!
     (lambda ()
       (call-with-cleanup
        (lambda ()
          ;; Keep the owner unreaped until signaling its group, avoiding PGID reuse.
          (kill (if group-ready? (- pid) pid) SIGKILL)
          (waitpid pid))
        (lambda ()
          (<= 'group-ready)
          (set! group-ready? #t)
          (proc (string-append "git://127.0.0.1:"
                               (number->string (<= 'port)) "/.git"))))))))
