;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox btrfs)
  #:use-module ((guix build syscalls) #:select (file-system-type statfs))
  #:use-module ((guix build utils) #:select (invoke))
  #:export (delete-testbox-root!
            require-testbox-base
            testbox-root-path))

;; Linux BTRFS_SUPER_MAGIC, from linux/magic.h.
(define BTRFS_SUPER_MAGIC #x9123683E)

(define (btrfs? path)
  (and path
       (file-exists? path)
       (= BTRFS_SUPER_MAGIC (file-system-type (statfs path)))))

(define* (require-testbox-base
          #:optional (testbox-btrfs (getenv "TESTBOX_BTRFS")))
  "Return the installed testbox base in TESTBOX-BTRFS."
  (unless (btrfs? testbox-btrfs)
    (error "testbox Btrfs filesystem is unavailable" testbox-btrfs))
  (let ((base (string-append testbox-btrfs "/base")))
    (unless (file-exists? base)
      (error "testbox base is not installed" base))
    base))

(define (btrfs)
  (or (search-path (string-split (or (getenv "PATH") "") #\:) "btrfs")
      (error "unable to find btrfs")))

(define (testbox-root-path pid1)
  "Return the testbox root path for PID1."
  (string-append (getenv "TESTBOX_BTRFS") "/testbox-roots/testbox-"
                 (number->string pid1)))

(define (delete-testbox-root! pid1)
  "Delete the testbox root owned by PID1."
  (invoke (btrfs) "--quiet" "subvolume" "delete"
          (testbox-root-path pid1)))
