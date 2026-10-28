;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd roots)
  #:use-module (gxd prelude)
  #:use-module ((gcrypt hash) #:select (sha1))
  #:use-module ((guix base32) #:select (bytevector->nix-base32-string))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type exception-kind exception-args
                          raise-exception with-exception-handler))
  #:use-module ((rnrs bytevectors) #:select (string->utf8))
  #:use-module ((srfi srfi-1) #:select (fold))
  #:use-module ((srfi srfi-13) #:select (string-join string-prefix?))
  #:export (register-indirect-root!
            &root-filesystem-error root-filesystem-error? root-filesystem-error-operation
            root-filesystem-error-paths root-filesystem-error-errno
            &root-not-directory root-not-directory? root-not-directory-path))

(define-exception-type &root-filesystem-error &error
  make-root-filesystem-error root-filesystem-error?
  (operation root-filesystem-error-operation)
  (paths root-filesystem-error-paths)
  (errno root-filesystem-error-errno))

(define-exception-type &root-not-directory &error
  make-root-not-directory root-not-directory?
  (path root-not-directory-path))

(define (filesystem-operation operation proc . paths)
  "Apply PROC to PATHS, preserving filesystem failures as OPERATION facts."
  (with-exception-handler
    (lambda (exception)
      (if (eq? 'system-error (exception-kind exception))
          (raise-exception
           (make-root-filesystem-error
            operation paths
            (system-error-errno (cons 'system-error (exception-args exception)))))
          (raise-exception exception)))
    (lambda () (apply proc paths))
    #:unwind? #t))

(define (mkdir-if-missing! path)
  (with-exception-handler
    (lambda (exception)
      (unless (and (eq? 'system-error (exception-kind exception))
                   (= EEXIST (system-error-errno (cons 'system-error (exception-args exception)))))
        (raise-exception exception)))
    (lambda () (mkdir path))
    #:unwind? #t))

(define (root-path-exists? path)
  ;; As in nixd, retry a failed inspection through parent-directory creation.
  (with-exception-handler
    (lambda (exception)
      (if (eq? 'system-error (exception-kind exception))
          #f
          (raise-exception exception)))
    (lambda () (lstat path) #t)
    #:unwind? #t))

(define (make-root-directory! path)
  "Create PATH and its ancestors, rejecting an existing non-directory."
  (unless (string=? path "/")
    (unless (root-path-exists? path)
      (make-root-directory! (dirname path))
      (filesystem-operation 'mkdir mkdir-if-missing! path))
    (unless (eq? 'directory (stat:type (filesystem-operation 'stat stat path)))
      (raise-exception (make-root-not-directory path)))))

;; Guix's `absolute-file-name' resolves symlinks; preserve the root link's path.
(define (absolute-root-path path)
  "Return PATH made absolute and lexically normalized, without resolving symlinks."
  (let* ((absolute (if (string-prefix? "/" path) path (string-append (getcwd) "/" path)))
         (components
          (fold (lambda (component result)
                  (cond
                   ((member component '("" ".")) result)
                   ((string=? component "..") (if (null? result) result (cdr result)))
                   (else (cons component result))))
                '() (string-split absolute #\/))))
    (string-append "/" (string-join (reverse components) "/"))))

(define (register-indirect-root! state-directory path)
  "Register PATH as an indirect GC root under STATE-DIRECTORY."
  (let* ((target (absolute-root-path path))
         (directory (string-append state-directory "/gcroots/auto"))
         (link (string-append directory "/"
                              (bytevector->nix-base32-string (sha1 (string->utf8 target)))))
         (temporary (string-append link ".tmp-" (number->string (getpid)) "-"
                                   (number->string (random (expt 2 32))))))
    (make-root-directory! directory)
    (filesystem-operation 'symlink symlink target temporary)
    (filesystem-operation 'rename rename-file temporary link)))
