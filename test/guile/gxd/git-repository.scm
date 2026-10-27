;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd git-repository)
  #:use-module (gxd prelude)
  #:use-module ((guix utils) #:select (call-with-temporary-directory with-environment-variables))
  #:use-module ((guix build utils) #:select (invoke))
  #:use-module ((ice-9 popen) #:select (open-pipe* close-pipe))
  #:use-module ((ice-9 rdelim) #:select (read-line))
  #:export (call-with-git-repository))

(define (call-with-git-repository git populate proc)
  "Populate a temporary directory with POPULATE, then commit its files using GIT.
Call PROC with the repository directory and commit ID; remove it on exit."
  (call-with-temporary-directory
   (lambda (directory)
     (populate directory)
     (with-environment-variables
      '(("GIT_CONFIG_NOSYSTEM" "1") ("GIT_CONFIG_GLOBAL" "/dev/null")
        ("GIT_AUTHOR_DATE" "2000-01-01T00:00:00+0000")
        ("GIT_COMMITTER_DATE" "2000-01-01T00:00:00+0000"))
      (invoke git "-C" directory "init" "--initial-branch=main")
      (invoke git "-C" directory "add" ".")
      (invoke git "-C" directory "-c" "user.name=Fixture"
              "-c" "user.email=fixture@example.invalid" "-c" "commit.gpgsign=false"
              "commit" "-m" "Fixture")
      (define pipe (open-pipe* OPEN_READ git "-C" directory "rev-parse" "HEAD"))
      (define commit
        (call-with-cleanup
         (lambda ()
           (unless (zero? (close-pipe pipe))
             (error "git rev-parse failed")))
         (lambda () (read-line pipe))))

      (proc directory commit)))))
