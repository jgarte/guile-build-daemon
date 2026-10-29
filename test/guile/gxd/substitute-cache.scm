;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd substitute-cache)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd http-server) #:select (call-with-http-server))
  #:use-module ((guix derivations) #:prefix guix-drv:
                #:select (derivation-file-name derivation->output-path))
  #:use-module ((guix serialization) #:select (write-file))
  #:use-module ((guix pki) #:select (signature-sexp))
  #:use-module ((guix base32) #:select (bytevector->nix-base32-string))
  #:use-module ((guix base64) #:select (base64-encode))
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module ((gcrypt pk-crypto)
                #:select (find-sexp-token canonical-sexp->string bytevector->hash-data
                          string->canonical-sexp))
  #:use-module ((rnrs bytevectors) #:select (bytevector-length string->utf8))
  #:use-module ((rnrs io ports) #:select (call-with-bytevector-output-port))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((web request) #:select (request-uri))
  #:use-module ((web response) #:select (build-response))
  #:use-module ((web uri) #:select (uri-path))
  #:export (call-with-substitute-cache))

(define (signature-field narinfo-text)
  "Return a Signature field authenticating NARINFO-TEXT with the test key."
  (let* ((keypair
          (call-with-resource "substitutes/test-signing-key.sexp"
                              (lambda (port) (string->canonical-sexp (slurp port)))))
         (public (find-sexp-token keypair 'public-key))
         (private (find-sexp-token keypair 'private-key))
         (hash-data
          (bytevector->hash-data (sha256 (string->utf8 narinfo-text)) #:key-type 'rsa)))
    (chain (signature-sexp hash-data private public)
      (canonical-sexp->string _)
      (string->utf8 _)
      (base64-encode _)
      (string-append "Signature: 1;fixture;" _ "\n"))))

(define (call-with-substitute-cache drv source-path proc)
  "Call PROC with the URL of a signed loopback substitute cache for DRV.
Serve the filesystem item at SOURCE-PATH as DRV's default output, with no
references and DRV as its deriver.  Sign with the testbox's public test key.
Stop and reap the server on return or exception; preserve PROC's values."
  (define output-path (guix-drv:derivation->output-path drv))
  (define nar
    (call-with-bytevector-output-port
     (lambda (port) (write-file source-path port))))

  (define narinfo-text
    (format #f "StorePath: ~a
URL: payload.nar
Compression: none
NarHash: sha256:~a
NarSize: ~a
References:
Deriver: ~a
"
            output-path
            (bytevector->nix-base32-string (sha256 nar))
            (bytevector-length nar)
            (basename (guix-drv:derivation-file-name drv))))

  (define narinfo (string-append narinfo-text (signature-field narinfo-text)))
  (define narinfo-route
    (string-append "/" (substring (basename output-path) 0 32) ".narinfo"))

  (define (handler request body)
    (let ((route (uri-path (request-uri request))))
      (cond ((string=? route narinfo-route)
             (values '((content-type . (text/plain))) narinfo))
            ((string=? route "/payload.nar")
             (values '((content-type . (application/octet-stream))) nar))
            ((string=? route "/nix-cache-info")
             (values '((content-type . (text/plain)))
                     "StoreDir: /gnu/store\nWantMassQuery: 0\n"))
            (else (values (build-response #:code 404) "not found")))))

  (call-with-http-server handler (lambda (url request-count) (proc url))))
