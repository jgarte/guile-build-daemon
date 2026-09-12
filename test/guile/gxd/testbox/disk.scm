;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox disk)
  #:use-module ((guix build syscalls) #:select (file-system-type statfs))
  #:use-module ((guix build utils) #:select (invoke mkdir-p))
  #:use-module ((gxd test-prelude) #:select (require-program))
  #:export (delete-testbox-root!
            require-testbox-base
            snapshot-base!))

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

(define (testbox-root-path pid1)
  "Return the testbox root path for PID1."
  (string-append (getenv "TESTBOX_DISK_MOUNT_POINT")
                 "/testbox-roots/testbox-"
                 (number->string pid1)))

(define (delete-testbox-root! pid1)
  "Delete the testbox root owned by PID1."
  (invoke (require-program "btrfs") "--quiet" "subvolume" "delete"
          (testbox-root-path pid1)))

(define (snapshot-base! pid1)
  "Snapshot the base into the testbox root owned by PID1 and return its path."
  (let ((base (require-testbox-base))
        (destination (testbox-root-path pid1)))
    (when (file-exists? destination)
      (error "testbox root already exists" destination))
    (mkdir-p (dirname destination))
    (invoke (require-program "btrfs") "--quiet" "subvolume" "snapshot"
            base destination)
    destination))
