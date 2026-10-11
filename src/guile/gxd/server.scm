;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd server)
  #:use-module ((gxd accounts) #:select (user-exists?))
  #:use-module ((gxd socket) #:select (peer-uid))
  #:use-module ((gxd database) #:select (call-with-database valid-path?)
                #:prefix database:)
  #:use-module ((gxd worker-protocol) #:select (read-integer read-string
                                                             write-completion write-error write-log)
                #:prefix protocol:)
  #:use-module ((guix config) #:select (%store-directory
                                        %store-database-directory))
  #:use-module ((guix remote-procedures) #:select (%protocol-version
                                                   %worker-magic-1
                                                   %worker-magic-2
                                                   remote-procedure-id))
  #:use-module ((guix serialization) #:select (boolean integer
                                                       write-value))
  #:use-module ((ice-9 exceptions) #:select (raise-exception
                                             with-exception-handler))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((ice-9 format) #:select (format))
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

(define (serve-client connection store-directory database-file)
  "Serve one validity query on CONNECTION using STORE-DIRECTORY and DATABASE-FILE."
  (greet-client connection)
  (database:call-with-database database-file
    (lambda (db)
      (define uid (peer-uid connection))
      (unless (user-exists? uid)
        (protocol:write-log (format #f "user with UID ~a not found~%" uid)
                            connection))

      (protocol:write-completion connection)
      (force-output connection)

      (unless (= (protocol:read-integer connection)
                 (remote-procedure-id valid-path?))
        (error "unsupported operation"))

      (define path (protocol:read-string connection))
      (define prefix (string-append store-directory "/"))
      (if (and (string-prefix? prefix path)
               (> (string-length path) (string-length prefix))
               (not (string-index path #\/ (string-length prefix))))
          (let ((valid? (database:valid-path? db path)))
            (protocol:write-completion connection)
            (write-value boolean valid? connection))
          (protocol:write-error
           (format #f "path `~a' is not in the store" path) 1 connection))
      (force-output connection))))

(define (run-server socket-path)
  "Serve one validity query at SOCKET-PATH against the configured store."
  (define listener (socket AF_UNIX SOCK_STREAM 0))

  (with-exception-handler
    (lambda (exception)
      (close-port listener)
      (raise-exception exception))
    (lambda ()
      ;; Like nixd's open_unix_socket, permit clients with other UIDs to connect.
      (let ((previous-mask (umask #o111)))
        (dynamic-wind
          (lambda () #t)
          (lambda () (bind listener AF_UNIX socket-path))
          (lambda () (umask previous-mask)))))
    #:unwind? #t)

  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (listen listener 1)
      (match (accept listener)
        ((connection . _)
         (dynamic-wind
           (lambda () #t)
           (lambda ()
             (serve-client connection %store-directory
                           (string-append %store-database-directory
                                          "/db.sqlite")))
           (lambda () (close-port connection))))))
    (lambda ()
      (close-port listener)
      (delete-file socket-path))))
