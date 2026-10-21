;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd store-files)
  #:use-module (gxd prelude)
  #:use-module ((guix build utils) #:select (false-if-file-not-found))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:export (delete-path!))

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
