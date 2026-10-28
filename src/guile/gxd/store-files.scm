;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd store-files)
  #:use-module (gxd prelude)
  #:use-module ((guix build utils) #:select (false-if-file-not-found))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception))
  #:export (delete-path! canonicalize-metadata! secure-file-permissions!
                         &unsupported-file-type-error unsupported-file-type-error?
                         unsupported-file-type-error-path unsupported-file-type-error-type))

(define-exception-type &unsupported-file-type-error &error
  make-unsupported-file-type-error unsupported-file-type-error?
  (path unsupported-file-type-error-path)
  (type unsupported-file-type-error-type))

(define (canonicalize-entry! path info)
  ;; Reject unsupported types before changing their metadata.
  (unless (memq (stat:type info) '(regular directory symlink))
    (raise-exception (make-unsupported-file-type-error path (stat:type info))))

  ;; Make entries read-only; owner-execute selects 0555 rather than 0444.
  (unless (eq? 'symlink (stat:type info))
    (define mode (if (zero? (logand (stat:perms info) #o100)) #o444 #o555))
    (unless (= mode (stat:perms info))
      (chmod path mode)))

  ;; Set mtime to 1, preserving atime.  Change symlinks themselves, not their targets.
  (unless (= 1 (stat:mtime info))
    (utime path (stat:atime info) 1 0 0 AT_SYMLINK_NOFOLLOW)))

(define (canonicalize-metadata! path)
  "Walk PATH depth-first, applying `canonicalize-entry!' before visiting children.
PATH and its descendants must belong to the current effective user.  Do not
follow symlinks.  Errors leave earlier metadata changes intact."
  (define info (lstat path))

  (canonicalize-entry! path info)
  (when (eq? 'directory (stat:type info))
    (for-each canonicalize-metadata! (directory-children path))))

(define (secure-file-permissions! path)
  "Remove setuid, setgid and world-write permissions from PATH's tree.
Do not follow symlinks; reject types other than regular files and directories.
PATH and its descendants belong to the caller and have no concurrent writers.
Preserve mtimes and other permission bits; propagate filesystem errors."
  (define info (lstat path))

  (case (stat:type info)
    ((symlink) #t)
    ((regular directory)
     (when (eq? 'directory (stat:type info))
       (for-each secure-file-permissions! (directory-children path)))
     (chmod path (logand (stat:perms info) (lognot #o6002))))
    (else
     (raise-exception (make-unsupported-file-type-error path (stat:type info))))))

(define (delete-path! path)
  "Remove PATH without following symlinks; do nothing if it is absent.
The caller must hold PATH's destination lock and establish that it is invalid.
Propagate filesystem errors rather than continuing with a partial deletion."
  (and-let* ((info (false-if-file-not-found (lstat path))))
    (if (eq? 'directory (stat:type info))
        (begin
          (chmod path (logior #o700 (stat:perms info)))
          (for-each
           (lambda (name) (delete-path! (string-append path "/" name)))
           (scandir path (lambda (name) (not (member name '("." ".."))))))
          (rmdir path))
        (delete-file path))))
