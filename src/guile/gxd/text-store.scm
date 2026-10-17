;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd text-store)
  #:use-module (gxd prelude)
  #:use-module ((guix build utils) #:select (false-if-file-not-found))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:export (write-text!))

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

(define (write-text! destination contents)
  "Write bytevector CONTENTS to DESTINATION; return its NAR SHA256 and size.
The caller owns its lock and validity registration.
Leave a read-only, non-executable regular file with modification time 1.
A failure may leave an unregistered file at DESTINATION."
  (let ((port (open destination (logior O_WRONLY O_CREAT O_TRUNC O_CLOEXEC) #o666)))
    (dynamic-wind
      (lambda () #t)
      (lambda () (put-bytevector port contents))
      (lambda () (close-port port))))
  (chmod destination #o444)
  ;; Store timestamps are one second after the epoch; preserve access time.
  (utime destination (stat:atime (stat destination)) 1)
  (nar-sha256 destination))
