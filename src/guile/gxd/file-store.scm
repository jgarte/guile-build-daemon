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
  #:export (add-nar-to-store
            call-with-bytevector-input-port
            call-with-bytevector-output-port
            register-store-path!
            restore-nar!
            ensure-store-path!
            call-with-nar-payload-and-store-path))

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

(define %directory-nesting-limit
  ;; Consult with Nix's DIRECTORY_NESTING_LIMIT
  (let ((value (getenv "DIRECTORY_NESTING_LIMIT")))
    (if value
        (let ((limit (string->number value)))
          (if (and (integer? limit) (positive? limit)) limit 256))
        256)))

(define (check-nar-depth file)
  "Reject a NAR entry deeper than Nix's directory nesting limit."
  (let loop ((index 0) (depth 0))
    ;; FILE starts at the NAR root.  Each slash is one directory below it,
    ;; whereas Nix counts the root as the first directory.
    (when (>= depth %directory-nesting-limit)
      (error "nar directory nesting limit reached"))
    (match (string-index file #\/ index)
      (#f #t)
      (next (loop (1+ next) (1+ depth))))))

(define (fold-nar port regular-file-callback other-files-callback)
  "Fold one NAR from PORT with file-type callbacks.

REGULAR-FILE-CALLBACK receives a regular or executable file's path, contents
port, and size.  OTHER-FILES-CALLBACK receives every directory or symlink's
path, type, and contents.  Callback return values are ignored."
  (fold-archive
   (lambda (file type contents _)
     (check-nar-depth file)
     (match type
       ((or 'regular 'executable)
        (regular-file-callback file (car contents) (cdr contents)))
       ((or 'directory 'directory-complete 'symlink)
        (other-files-callback file type contents)))
     #t)
   #t port ""))

(define (read-nar port)
  "Consume one NAR from PORT and return its bytes."
  (call-with-bytevector-output-port
   (lambda (output)
     ;; INPUT is a custom view of PORT and does not own PORT.
     (let ((input (tee-input-port port output)))
       (fold-nar input
         (lambda (_ contents size) (drain contents size))
         (lambda _ #t))))))

(define (fixed-output-hash-algorithm name)
  "Return NAME as a supported fixed-output hash-algorithm and gcrypt value."
  (let ((algorithm (string->symbol name)))
    (unless (memq algorithm '(md5 sha1 sha256 sha512))
      (error "unknown hash algorithm" name))
    (values algorithm (lookup-hash-algorithm algorithm))))

(define (read-content-of-flat-file-nar port)
  "Consume one flat NAR from PORT and return its root regular file contents."
  (call-with-bytevector-output-port
   (lambda (output)
     (fold-nar port
       (lambda (file contents size)
         (unless (string-null? file)
           (error "flat NAR must contain one root regular file" file))
         (drain contents size output))
       (lambda (file type _)
         (error "flat NAR must contain one root regular file" type file))))))


(define* (register-store-path! db store-directory destination
                              #:key nar-hash nar-size)
  "Register DESTINATION in DB with its NAR hash and size.
When NAR-HASH and NAR-SIZE are supplied, they describe a validated canonical
NAR which was used to restore DESTINATION."
  (let-values (((nar-hash nar-size)
                (if nar-hash
                    (values nar-hash nar-size)
                    (nar-sha256 destination))))
    (database:register-item!
     db store-directory destination nar-hash nar-size '())))

(define (restore-nar! destination nar)
  "Restore bytevector NAR at DESTINATION with canonical metadata."
  (call-with-bytevector-input-port nar
    (lambda (input) (restore-file input destination))))

(define* (ensure-store-path! db store-directory destination write-to-store!
                            #:key nar-hash nar-size)
  "Ensure DESTINATION exists in DB, using WRITE-TO-STORE! to create it when needed.
NAR-HASH and NAR-SIZE may describe the validated NAR written by WRITE-TO-STORE!."
  (unless (database:valid-path? db destination)
    (call-with-destination-lock destination
      (lambda ()
        ;; Another session may have imported this item while we waited.
        (unless (database:valid-path? db destination)
          (delete-path! destination)
          (write-to-store!)
          (register-store-path! db store-directory destination
                                #:nar-hash nar-hash #:nar-size nar-size))))))

(define (call-with-nar-payload-and-store-path store-directory name recursive?
                                           hash-algo port proc)
  "Read one NAR from PORT and call PROC with its payload, store destination,
and NAR hash and size.  The latter are supplied only when RECURSIVE? is true.
The payload is the NAR when RECURSIVE? is true, otherwise its root file
contents."
  (let-values (((algorithm gcrypt-algorithm)
                (fixed-output-hash-algorithm hash-algo)))
    (let* ((payload (if recursive?
                        (read-nar port)
                        (read-content-of-flat-file-nar port)))
           (hash (bytevector-hash payload gcrypt-algorithm))
           ;; A recursive NAR is canonical. So restoring it and serializing the
           ;; result should produce the same bytes
           (nar-hash (and recursive?
                          (if (eq? algorithm 'sha256)
                              hash
                              (bytevector-hash
                               payload (lookup-hash-algorithm 'sha256)))))
           (nar-size (and recursive? (bytevector-length payload)))
           (destination
            (fixed-output-path store-directory name hash
                               #:hash-algo algorithm #:recursive? recursive?)))
      (proc payload destination nar-hash nar-size))))

(define* (add-nar-to-store #:key db store-directory name recursive? hash-algo port)
  "Read one NAR from PORT and add it as the fixed-output item NAME.
When RECURSIVE? is true, hash the NAR and restore its file tree; otherwise,
hash and store its root regular file's contents.  Return the store path."
  (call-with-nar-payload-and-store-path
   store-directory name recursive? hash-algo port
   (lambda (payload destination nar-hash nar-size)
     (ensure-store-path!
      db store-directory destination
      (lambda ()
        (if recursive?
            (restore-nar! destination payload)
            (write-text! destination payload)))
      #:nar-hash nar-hash #:nar-size nar-size)
     destination)))
