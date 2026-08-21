;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox disk)
  #:use-module ((guix build syscalls) #:select (file-system-type statfs))
  #:export (require-testbox-base))

;; Linux BTRFS_SUPER_MAGIC, from linux/magic.h.
(define BTRFS_SUPER_MAGIC #x9123683E)

(define (btrfs? path)
  (and path
       (file-exists? path)
       (= BTRFS_SUPER_MAGIC (file-system-type (statfs path)))))

(define* (require-testbox-base
          #:optional (base (getenv "TESTBOX_DISK_BASE_SUBVOLUME_PATH")))
  "Return BASE when it is available on the testbox disk."
  (unless (btrfs? base)
    (error "testbox disk base is unavailable" base))
  base)
