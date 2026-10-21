;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd text-store)
  #:use-module (gxd prelude)
  #:use-module ((gxd database)
                #:prefix database:
                #:select (valid-path? register-text! register-derivation!))
  #:use-module ((gxd path-locks) #:select (call-with-destination-lock))
  #:use-module ((gxd store-path) #:select (text-path))
  #:use-module ((gxd store-files) #:select (delete-path!))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((rnrs io ports) #:select (put-bytevector))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (write-text! add-text!))

(define (add-text! db store-directory name contents references)
  "Add NAME with bytevector CONTENTS and REFERENCES to the store.
Return its path in STORE-DIRECTORY, registered in DB.  REFERENCES must be sorted
unique store paths validated by the caller.  Leave already-valid items untouched.
The caller must exclude concurrent GC."
  (let ((destination (text-path store-directory name contents references)))
    (unless (database:valid-path? db destination)
      (call-with-destination-lock destination
        (lambda ()
          (unless (database:valid-path? db destination)
            (delete-path! destination)
            (let-values (((hash size) (write-text! destination contents)))
              (if (string-suffix? ".drv" name)
                  (database:register-derivation!
                   db store-directory destination hash size references)
                  (database:register-text! db destination hash size references)))))))
    destination))

(define (write-text! destination contents)
  "Write bytevector CONTENTS to DESTINATION; return its NAR SHA256 and size.
The caller owns its lock and validity registration.
Leave a read-only, non-executable regular file with modification time 1.
A failure may leave an unregistered file at DESTINATION."
  (let ((port (open destination (logior O_WRONLY O_CREAT O_TRUNC O_CLOEXEC) #o666)))
    (call-with-cleanup
     (lambda () (close-port port))
     (lambda () (put-bytevector port contents))))
  (chmod destination #o444)
  ;; Store timestamps are one second after the epoch; preserve access time.
  (utime destination (stat:atime (stat destination)) 1)
  (nar-sha256 destination))
