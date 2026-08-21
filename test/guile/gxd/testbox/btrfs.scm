;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox btrfs)
  #:use-module ((guix build syscalls) #:select (file-system-type statfs))
  #:export (require-testbox-base))

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
