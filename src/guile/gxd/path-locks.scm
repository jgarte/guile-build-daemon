;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd path-locks)
  #:use-module (gxd prelude)
  #:use-module ((guix build syscalls) #:select (fcntl-flock))
  #:use-module ((guix build utils) #:select (false-if-file-not-found))
  #:use-module ((ice-9 exceptions)
                #:select (exception-args exception-kind raise-exception
                                         with-exception-handler))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((srfi srfi-1) #:select (delete-duplicates))
  #:export (call-with-destination-lock call-with-destination-locks))

;;; Destination locks
;;;
;;; Each writer opens DESTINATION.lock and takes an exclusive POSIX fcntl lock.
;;; Locks protect inodes, not pathnames: a waiter may acquire an inode that its
;;; previous holder has already unlinked.  After locking, compare the descriptor's
;;; device/inode with the pathname's; reopen and retry if they differ or the name
;;; is absent.  Once they match, cooperating writers cannot unlink that file
;;; until this owner releases it.
;;;
;;; Release attempts unlink before close, on both normal and exceptional exit.
;;; If unlink fails, close still releases the lock; the next writer can reuse
;;; the retained inode.  Every writer must follow the same ownership protocol.

;;; Differences from nixd
;;;
;;; nix/libstore/pathlocks.cc detects stale inodes by writing a marker after
;;; unlinking; waiters reject nonempty lock files.  Here file contents are ignored
;;; and identity is checked instead.  A failed unlink therefore cannot leave a
;;; marked pathname that all later acquisitions continually reject.  We also
;;; unlink after a failed operation, rather than only after success.

(define (write-lock port)
  (or (with-exception-handler
        (lambda (exception)
          (match (cons (exception-kind exception) (exception-args exception))
            (('flock-error errno)
             (if (= errno EINTR) #f (raise-exception exception)))
            (_ (raise-exception exception))))
        (lambda () (fcntl-flock port 'write-lock) #t)
        #:unwind? #t)
      (write-lock port)))

(define (current-lock? file port)
  (let ((opened (stat port))
        (named (false-if-file-not-found (stat file))))
    (and named
         (= (stat:dev opened) (stat:dev named))
         (= (stat:ino opened) (stat:ino named)))))

(define (acquire-lock file)
  (let ((port (open file (logior O_RDWR O_CREAT O_CLOEXEC) #o600))
        (current? #f))
    (call-with-cleanup
     (lambda () (unless current? (close-port port)))
     (lambda ()
       (write-lock port)
       (set! current? (current-lock? file port))))

    ;; A previous holder may have unlinked the inode while we waited on it.
    (if current? port (acquire-lock file))))

(define (release-lock file port)
  "Unlink FILE and close PORT to release its lock.
Report cleanup failures without propagating them."
  (with-exception-handler
    (lambda (exception)
      (format (current-error-port) "error releasing lock ~a: ~s~%"
              file exception))
    (lambda ()
      ;; Closing must release the kernel lock even when unlinking fails.
      (call-with-cleanup
       (lambda () (close-port port))
       (lambda () (delete-file file))))
    #:unwind? #t))

(define (call-with-destination-lock destination thunk)
  "Call THUNK holding DESTINATION's exclusive store-path lock.
Return THUNK's values and release the lock when THUNK exits.
This scope must not nest another lock on DESTINATION."
  (let* ((file (string-append destination ".lock"))
         (port (acquire-lock file)))
    (call-with-cleanup
     (lambda () (release-lock file port))
     thunk)))

(define (call-with-destination-locks destinations thunk)
  "Call THUNK holding the exclusive locks for distinct DESTINATIONS.
Acquire in pathname order, return THUNK's values and release on return or
exception.  The caller must not already hold any of these locks."
  (let acquire ((paths (sort (delete-duplicates destinations string=?) string<?)))
    (match paths
      (() (thunk))
      ((path . rest)
       (call-with-destination-lock path
         (lambda () (acquire rest)))))))
