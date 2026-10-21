;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd derivations)
  #:use-module ((gxd store-path) #:select (check-store-name))
  #:use-module ((gcrypt hash) #:select (lookup-hash-algorithm hash-size))
  #:use-module ((guix base16) #:select (bytevector->base16-string))
  #:use-module ((guix derivations)
                #:prefix guix-drv:
                #:select (read-derivation derivation-outputs derivation-output-path
                                          derivation-output-hash derivation-output-hash-algo
                                          derivation-output-recursive? derivation-hash
                                          derivation-builder-environment-vars
                                          derivation-inputs derivation-input-derivation))
  #:use-module ((guix store)
                #:prefix guix-store:
                #:select (%store-prefix output-path fixed-output-path
                                        store-path-package-name))
  #:use-module ((ice-9 exceptions)
                #:select (&error define-exception-type raise-exception))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((ice-9 match) #:select (match match-lambda match-lambda*))
  #:use-module ((rnrs bytevectors) #:select (bytevector-length))
  #:use-module ((srfi srfi-9 gnu) #:select (set-fields))
  #:use-module ((srfi srfi-13) #:select (string-drop-right))
  #:export (read-derivation resolve-inputs! check-outputs
                            &derivation-output-error derivation-output-error?
                            derivation-output-error-message))

(define-exception-type &derivation-output-error &error
  make-derivation-output-error derivation-output-error?
  (message derivation-output-error-message))

(define binding-name<?
  (match-lambda*
    (((left-name . _) (right-name . _))
     (string<? left-name right-name))))

(define (read-derivation port)
  "Read a derivation from PORT without loading its input derivations.
Input records hold filenames under `derivation-input-derivation' until resolved.
Output declarations and environment bindings are sorted by name.
Accept the syntax understood by Guix's reader; decoding errors propagate."
  (let ((drv (guix-drv:read-derivation port identity)))
    (set-fields drv
      ((guix-drv:derivation-outputs)
       (sort (guix-drv:derivation-outputs drv) binding-name<?))
      ((guix-drv:derivation-builder-environment-vars)
       (sort (guix-drv:derivation-builder-environment-vars drv) binding-name<?)))))

(define (resolve-inputs! drv load-input)
  "Return a copy of decoded DRV with ordinary input derivations resolved by LOAD-INPUT.
LOAD-INPUT takes a filename and returns a derivation with its inputs resolved.
Fixed-output derivations are retained without loading their inputs.
Loader errors propagate."
  (if (fixed-output drv)
      drv
      (set-fields drv
        ((guix-drv:derivation-inputs)
         (map (lambda (input)
                (set-fields input
                  ((guix-drv:derivation-input-derivation)
                   (load-input (guix-drv:derivation-input-derivation input)))))
              (guix-drv:derivation-inputs drv))))))

(define (mask-outputs drv)
  "Return a copy of DRV with its output paths and corresponding environment values empty."
  (let* ((outputs (guix-drv:derivation-outputs drv))
         (environment (guix-drv:derivation-builder-environment-vars drv))
         (environment (append
                       ;; Preserve non-output environment values.
                       (filter (match-lambda
                                 ((name . _) (not (assoc name outputs))))
                               environment)
                       ;; Empty each output value, inserting it if absent.
                       (map (match-lambda ((name . _) (cons name ""))) outputs))))
    (set-fields drv
      ((guix-drv:derivation-outputs)
       (map (match-lambda
              ((name . output)
               (cons name
                     (set-fields output ((guix-drv:derivation-output-path) "")))))
            outputs))
      ((guix-drv:derivation-builder-environment-vars)
       (sort environment binding-name<?)))))

(define (fixed-output drv)
  (match (guix-drv:derivation-outputs drv)
    ((("out" . output)) (and (guix-drv:derivation-output-hash output) output))
    (_ #f)))

(define (check-output-hash output)
  "Check OUTPUT's fixed hash algorithm and digest length."
  (let* ((algorithm (guix-drv:derivation-output-hash-algo output))
         (label (case algorithm
                  ((md5) "MD5")
                  ((sha1) "SHA1")
                  ((sha256) "SHA256")
                  ((sha512) "SHA512")
                  ((sha3-256) "SHA3-256")
                  ((sha3-512) "SHA3-512")
                  ((blake2s-256) "BLAKE2S_256")
                  (else #f))))
    (unless label
      (raise-exception
       (make-derivation-output-error
        (format #f "unknown hash algorithm `~a'" algorithm))))

    (let* ((hash (guix-drv:derivation-output-hash output))
           (size (bytevector-length hash))
           (expected (hash-size (lookup-hash-algorithm algorithm))))
      (unless (= size expected)
        (raise-exception
         (make-derivation-output-error
          (format #f "invalid ~a hash '~a' (~a bytes but expected ~a)"
                  label (bytevector->base16-string hash) size expected)))))))

(define (check-outputs store-directory path drv)
  "Check the output paths and environment of DRV admitted at PATH in STORE-DIRECTORY.
DRV must be a canonical Guix derivation with resolved input derivation records.
Raise a derivation-output error on a mismatch.  No files or database are read."
  (define name
    (parameterize ((guix-store:%store-prefix store-directory))
      (string-drop-right (guix-store:store-path-package-name path) 4)))

  (define outputs (guix-drv:derivation-outputs drv))
  (define fixed (fixed-output drv))

  (when fixed (check-output-hash fixed))

  (define hash
    (and (not fixed) (guix-drv:derivation-hash (mask-outputs drv))))

  (parameterize ((guix-store:%store-prefix store-directory))
    (for-each
     (match-lambda
       ((output-name . output)
        (check-store-name
         (if (or fixed (string=? output-name "out"))
             name
             (string-append name "-" output-name)))
        (let* ((declared-path (guix-drv:derivation-output-path output))
               (expected-path
                (if fixed
                    (guix-store:fixed-output-path
                     name (guix-drv:derivation-output-hash fixed)
                     #:hash-algo (guix-drv:derivation-output-hash-algo fixed)
                     #:recursive? (guix-drv:derivation-output-recursive? fixed))
                    (guix-store:output-path output-name hash name))))
          (unless (and (string=? declared-path expected-path)
                       (equal? expected-path
                               (assoc-ref (guix-drv:derivation-builder-environment-vars drv)
                                          output-name)))
            (raise-exception
             (make-derivation-output-error
              (format #f "derivation `~a' has incorrect output `~a', should be `~a'"
                      path declared-path expected-path)))))))
     outputs)))
