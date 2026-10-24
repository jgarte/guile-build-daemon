;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd server)
  #:use-module (gxd prelude)
  #:use-module ((gxd accounts) #:select (user-exists?))
  #:use-module ((gxd socket) #:select (peer-uid))
  #:use-module ((gxd session) #:select (&option-error option-error-message
                                                      initial-options update-options
                                                      unix-peer-trusted? options-build-cores))
  #:use-module ((gxd build)
                #:select (build-paths! &build-request-error build-request-error-path
                                       build-request-error-cause))
  #:use-module ((gxd build realization) #:select (builder-exit-error?))
  #:use-module ((gxd build outputs) #:select (missing-output-error? output-permission-error?))
  #:use-module ((gxd database) #:select (call-with-database valid-path?
                                                            invalid-reference?
                                                            invalid-reference-path)
                #:prefix database:)
  #:use-module ((gxd store-path)
                #:select (store-path? leading-dot-name-error? store-name-error-name
                                      invalid-character-name-error?
                                      invalid-character-name-error-character))
  #:use-module ((gxd text-store) #:select (add-text!))
  #:use-module ((gxd derivations)
                #:select (derivation-output-error? derivation-output-error-message))
  #:use-module ((gxd worker-protocol) #:select (read-integer read-string read-options read-text
                                                             read-string-list write-log-bytes
                                                             write-completion write-error write-log)
                #:prefix protocol:)
  #:use-module ((guix config) #:select (%store-directory
                                        %store-database-directory))
  #:use-module ((guix build utils) #:select (mkdir-p))
  #:use-module ((guix remote-procedures) #:select (%protocol-version
                                                   %worker-magic-1
                                                   %worker-magic-2
                                                   remote-procedure-id))
  #:use-module ((guix serialization) #:select (boolean integer utf8-string
                                                       write-value))
  #:use-module ((ice-9 exceptions) #:select (raise-exception
                                             with-exception-handler))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((rnrs io ports) #:select (lookahead-u8))
  #:export (run-server))

(define (greet-client connection)
  "Accept the pinned worker protocol on CONNECTION and return its version."
  (unless (= (protocol:read-integer connection) %worker-magic-1)
    (error "protocol mismatch"))
  (write-value integer %worker-magic-2 connection)
  (write-value integer %protocol-version connection)
  (force-output connection)

  (let ((version (protocol:read-integer connection)))
    (unless (= version %protocol-version)
      (error "unsupported client protocol version" version))
    (when (not (zero? (protocol:read-integer connection)))
      (protocol:read-integer connection))
    (protocol:read-integer connection)
    version))

(define (serve-request connection store-directory db options trusted?)
  "Serve one request on CONNECTION using STORE-DIRECTORY, DB, OPTIONS and TRUSTED?.
Return the session options after the request."
  (define operation (protocol:read-integer connection))

  (cond
   ((= operation (remote-procedure-id set-options))
    (call-with-option-error-reporting connection
      (lambda ()
        (set! options
              (update-options options (protocol:read-options connection) trusted?))
        (protocol:write-completion connection))))

   ((= operation (remote-procedure-id valid-path?))
    (let ((path (protocol:read-string connection)))
      (if (not (store-path? store-directory path))
          (protocol:write-error
           (format #f "path `~a' is not in the store" path) 1 connection)
          (let ((valid? (database:valid-path? db path)))
            (protocol:write-completion connection)
            (write-value boolean valid? connection)))))

   ((= operation (remote-procedure-id add-text-to-store))
    (let* ((request (protocol:read-text connection))
           (name (get request 'name))
           (references (get request 'references)))
      ;; nixd validates the complete reference set before startWork.
      (for-each
       (lambda (reference)
         (unless (store-path? store-directory reference)
           (protocol:write-error
            (format #f "path `~a' is not in the store" reference) 1 connection)
           (force-output connection)
           (error "reference is not in the store" reference)))
       references)

      (call-with-text-error-reporting connection
        (lambda ()
          (let ((path (add-text! db store-directory name
                                 (get request 'contents) references)))
            (protocol:write-completion connection)
            (write-value utf8-string path connection))))))

   ((= operation (remote-procedure-id build-things))
    (let* ((paths (protocol:read-string-list connection))
           (mode (protocol:read-integer connection)))
      (define build-directory-parent (or (getenv "TMPDIR") "/tmp"))
      (define (log! bytes)
        (protocol:write-log-bytes bytes connection)
        (force-output connection))

      (call-with-build-error-reporting connection
        (lambda ()
          (build-paths! db store-directory paths mode build-directory-parent
                        (options-build-cores options) log!)

          (protocol:write-completion connection)
          (write-value boolean #t connection)))))

   (else (error "unsupported operation")))

  (force-output connection)
  options)

(define (call-with-build-error-reporting connection thunk)
  "Call THUNK, reporting build request errors on CONNECTION without ending the session."
  (with-exception-handler
    (lambda (exception)
      (define cause (build-request-error-cause exception))
      (define status
        (cond
         ((builder-exit-error? cause) 100)
         ((or (missing-output-error? cause) (output-permission-error? cause)) 1)
         (else (raise-exception exception))))

      (protocol:write-error
       (format #f "build of `~a' failed" (build-request-error-path exception))
       status connection))
    thunk
    #:unwind? #t
    #:unwind-for-type &build-request-error))

(define (call-with-option-error-reporting connection thunk)
  "Call THUNK, reporting option errors on CONNECTION before re-raising them."
  (with-exception-handler
    (lambda (exception)
      (protocol:write-error (option-error-message exception) 1 connection)
      (force-output connection)
      (raise-exception exception))
    thunk
    #:unwind? #t
    #:unwind-for-type &option-error))

(define (call-with-text-error-reporting connection thunk)
  "Call THUNK, reporting name, reference or derivation-output errors on CONNECTION.
These errors end the request, not the client session; other exceptions propagate."
  (with-exception-handler
    (lambda (exception)
      (protocol:write-error
       (cond
        ((leading-dot-name-error? exception)
         (format #f "invalid name: `~a' (can't begin with dot)"
                 (store-name-error-name exception)))
        ((invalid-character-name-error? exception)
         (format #f "invalid character `~a' in name `~a'"
                 (invalid-character-name-error-character exception)
                 (store-name-error-name exception)))
        ((database:invalid-reference? exception)
         (format #f "path `~a' is not valid" (database:invalid-reference-path exception)))
        ((derivation-output-error? exception)
         (derivation-output-error-message exception))
        (else (raise-exception exception)))
       1 connection))
    thunk
    #:unwind? #t))

(define (serve-client connection store-directory database-file)
  "Serve supported requests until CONNECTION ends, using STORE-DIRECTORY and DATABASE-FILE."
  (greet-client connection)
  ;; LocalStore creates this index even when automatic deduplication is disabled.
  (mkdir-p (string-append store-directory "/.links"))
  (database:call-with-database database-file
    (lambda (db)
      (define uid (peer-uid connection))
      (define trusted? (unix-peer-trusted? uid (getuid)))
      (define options (initial-options #t))
      (unless (user-exists? uid)
        (protocol:write-log (format #f "user with UID ~a not found~%" uid)
                            connection))

      (protocol:write-completion connection)
      (force-output connection)

      (while (not (eof-object? (lookahead-u8 connection)))
             (set! options
                   (serve-request connection store-directory db options trusted?))))))

(define (run-server socket-path)
  "Serve one client session at SOCKET-PATH against the configured store."
  (define listener (socket AF_UNIX SOCK_STREAM 0))

  ;; Make new files and directories non-group/world-writable, as in nixd.
  (umask #o022)

  (with-exception-handler
    (lambda (exception)
      (close-port listener)
      (raise-exception exception))
    (lambda ()
      ;; Like nixd's open_unix_socket, permit clients with other UIDs to connect.
      (let ((previous-mask (umask #o111)))
        (call-with-cleanup
         (lambda () (umask previous-mask))
         (lambda () (bind listener AF_UNIX socket-path)))))
    #:unwind? #t)

  (call-with-cleanup
   (lambda ()
     (close-port listener)
     (delete-file socket-path))
   (lambda ()
     (listen listener 1)
     (match (accept listener)
       ((connection . _)
        (call-with-cleanup
         (lambda () (close-port connection))
         (lambda ()
           (serve-client connection %store-directory
                         (string-append %store-database-directory
                                        "/db.sqlite")))))))))
