;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd file-store)
  #:use-module (gxd prelude)
  #:use-module ((gxd database) #:prefix database:
                #:select (valid-path? register-item!))
  #:use-module ((gxd path-locks) #:select (call-with-destination-lock))
  #:use-module ((gxd store-files) #:select (delete-path!))
  #:use-module ((gxd store-path) #:select (fixed-output-path))
  #:use-module ((gxd text-store) #:select (write-text!))
  #:use-module ((gcrypt hash) #:select (bytevector-hash lookup-hash-algorithm))
  #:use-module ((guix serialization) #:select (fold-archive restore-file))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((rnrs bytevectors) #:select (bytevector-length))
  #:use-module ((rnrs io ports) #:select (get-bytevector-n get-bytevector-n!
                                                           make-custom-binary-input-port
                                                           open-bytevector-input-port
                                                           open-bytevector-output-port
                                                           put-bytevector))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (add-nar-as-recursive! add-nar-as-recursive-from-port!
                                  add-nar-as-flat-file! add-nar-as-flat-file-from-port!))

(define (call-with-bytevector-output-port proc)
  "Call PROC with an output port and return its accumulated bytevector."
  (let-values (((output extract) (open-bytevector-output-port)))
    (call-with-cleanup
     (lambda () (close-port output))
     (lambda ()
       (proc output)
       (extract)))))

(define (call-with-bytevector-input-port bytes proc)
  "Call PROC with an input port over BYTES."
  (let ((port (open-bytevector-input-port bytes)))
    (call-with-cleanup
     (lambda () (close-port port))
     (lambda () (proc port)))))

(define* (drain port size #:optional output)
  "Read exactly SIZE bytes from PORT, copying them to OUTPUT when supplied."
  (let loop ((remaining size))
    (unless (zero? remaining)
      (let ((bytes (get-bytevector-n port (min remaining 65536))))
        (when (eof-object? bytes)
          (error "unexpected end-of-file in NAR contents"))
        (when output (put-bytevector output bytes))
        (loop (- remaining (bytevector-length bytes)))))))

(define (tee-input-port input output)
  "Return an input port that copies bytes read from INPUT to OUTPUT."
  (define (read! bytes start count)
    (let ((read (get-bytevector-n! input bytes start count)))
      (cond ((eof-object? read) 0)
            ((zero? read) (read! bytes start count))
            (else
             (put-bytevector output bytes start read)
             read))))
  (let ((port (make-custom-binary-input-port
               "NAR saving input port" read! #f #f #f)))
    ;; Disable buffering so this port doesn't read ahead and steal bytes.
    ;; This ensures the caller can cleanly resume reading from the original 
    ;; input port later.
    (setvbuf port 'none)
    port))

(define (fold-nar port regular-file-callback other-files-callback)
  "Fold one NAR from PORT with file-type callbacks.

REGULAR-FILE-CALLBACK receives a regular or executable file's path, contents
port, and size.  OTHER-FILES-CALLBACK receives every directory or symlink's
path, type, and contents.  Callback return values are ignored."
  (fold-archive
   (lambda (file type contents _)
     (match type
       ((or 'regular 'executable)
        (regular-file-callback file (car contents) (cdr contents)))
       ((or 'directory 'directory-complete 'symlink)
        (other-files-callback file type contents)))
     #t)
   #t port ""))

(define (read-nar port)
  "Read, validate, and return one normalized NAR from PORT."
  (call-with-bytevector-output-port
   (lambda (output)
     ;; INPUT is a custom view of PORT and does not own PORT.
     (let ((input (tee-input-port port output)))
       (fold-nar input
         (lambda (_ contents size)
           (drain contents size))
         (lambda _ #t))))))

(define (fixed-output-hash-algorithm name)
  "Return NAME as a supported fixed-output hash-algorithm and gcrypt value."
  (let ((algorithm (string->symbol name)))
    (unless (memq algorithm '(md5 sha1 sha256 sha512))
      (error "unknown hash algorithm" name))
    (values algorithm (lookup-hash-algorithm algorithm))))

(define (read-content-of-flat-file-nar nar)
  "Return NAR's top-level regular file contents, or raise otherwise."
  (call-with-bytevector-output-port
   (lambda (output)
     (define regular? #f)
     (call-with-bytevector-input-port nar
       (lambda (input)
         (fold-nar input
           (lambda (file contents size)
             (if (string-null? file)
                 (begin
                   (set! regular? #t)
                   (drain contents size output))
                 (drain contents size)))
           (lambda _ #t))))
     (unless regular?
       (error "regular file expected")))))

(define (add-nar-as-flat-file! db store-directory name hash hash-algo contents)
  "Add bytevector CONTENTS as a flat fixed-output item named NAME."
  (let ((destination
         (fixed-output-path store-directory name hash
                            #:hash-algo hash-algo #:recursive? #f)))
    (unless (database:valid-path? db destination)
      (call-with-destination-lock destination
        (lambda ()
          (unless (database:valid-path? db destination)
            (delete-path! destination)
            (let-values (((nar-hash nar-size)
                          (write-text! destination contents)))
              (database:register-item!
               db store-directory destination nar-hash nar-size '()))))))
    destination))

(define (add-nar-as-flat-file-from-port! db store-directory name hash-algo port)
  "Read one flat-file NAR from PORT and add it as NAME to STORE-DIRECTORY."
  (let-values (((algorithm gcrypt-algorithm)
                (fixed-output-hash-algorithm hash-algo)))
    (let* ((nar (read-nar port))
           (contents (read-content-of-flat-file-nar nar))
           (hash (bytevector-hash contents gcrypt-algorithm)))
      (add-nar-as-flat-file! db store-directory name hash algorithm contents))))

(define (add-nar-as-recursive! db store-directory name hash hash-algo nar)
  "Restore buffered NAR as a recursive fixed-output item named NAME.
HASH is NAR's digest according to HASH-ALGO.  Return its store path.  NAR must
contain one valid normalized NAR.  An already-valid destination is left
unchanged.  The caller excludes concurrent GC."
  (let ((destination
         (fixed-output-path store-directory name hash
                            #:hash-algo hash-algo #:recursive? #t)))
    (unless (database:valid-path? db destination)
      (call-with-destination-lock destination
        (lambda ()
          ;; Recheck the db one more time in case another daemon session was
          ;; doing the same import while this one was waiting for the
          ;; destination lock
          (unless (database:valid-path? db destination)
            (delete-path! destination)
            (call-with-bytevector-input-port nar
              (lambda (input)
                (restore-file input destination)))
            (let-values (((nar-hash nar-size) (nar-sha256 destination)))
              (database:register-item!
               db store-directory destination nar-hash nar-size '()))))))
    destination))

(define (add-nar-as-recursive-from-port! db store-directory name hash-algo port)
  "Read one recursive NAR from PORT and add it as NAME to STORE-DIRECTORY."
  (let-values (((algorithm gcrypt-algorithm)
                (fixed-output-hash-algorithm hash-algo)))
    (let* ((nar (read-nar port))
           (hash (bytevector-hash nar gcrypt-algorithm)))
      (add-nar-as-recursive! db store-directory name hash algorithm nar))))
