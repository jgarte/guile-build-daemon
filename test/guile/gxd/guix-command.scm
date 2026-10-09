;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd guix-command)
  #:use-module ((gxd testbox)
                #:select (start-guix-command! wait-testbox-process!))
  #:use-module (gxd test-prelude)
  #:export (guix-command-fixture))

(define (paired-command! left right role arguments)
  (let* ((deadline (+ 5 (current-time)))
         (left-process (start-guix-command! left role arguments))
         (right-process (start-guix-command! right role arguments))
         (left-status (wait-testbox-process! left-process #:deadline deadline))
         (right-status (wait-testbox-process! right-process #:deadline deadline)))
    (unless (equal? left-status right-status)
      (error "Guix command results differ" arguments left-status right-status))
    (or (status:exit-val left-status)
        (error "Guix command terminated abnormally"
               arguments left-status right-status))))

(define (guix-command-fixture ctx proceed)
  "Add guix-command! to CTX, accepting literal string arguments.
E.g., (guix-command! \"gc\" \"--references\" path).
Run against testbox/left and testbox/right according to client/trusted?.
Return their common exit code, including nonzero results; raise on raw status
mismatch, abnormal termination or a shared five-second deadline.
On failure the caller must end the box scopes.
Standard output and error are inherited, not compared."
  (unless (and (assq 'testbox/left ctx)
               (assq 'testbox/right ctx)
               (assq 'client/trusted? ctx))
    (error "Guix command fixture requires boxes and client trust"))
  (let ((left (get ctx 'testbox/left))
        (right (get ctx 'testbox/right))
        (role (if (get ctx 'client/trusted?) 'daemon 'user)))
    (proceed
     (acons 'guix-command!
            (lambda arguments (paired-command! left right role arguments))
            ctx)
     (lambda () #t))))
