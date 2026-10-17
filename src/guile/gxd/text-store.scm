;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd text-store)
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:export (write-text!))

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
