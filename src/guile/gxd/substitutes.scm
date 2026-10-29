;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd substitutes)
  #:use-module (gxd prelude)
  #:use-module ((gxd session) #:select (options-substitute-urls))
  #:use-module ((guix narinfo) #:select (valid-narinfo?))
  #:use-module ((guix substitutes) #:select (lookup-narinfos/diverse))
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((srfi srfi-1) #:select (every))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:use-module ((web uri) #:select (uri-scheme string->uri))
  #:export (lookup-substitutes))

(define (configured-substitute-urls options)
  "Return OPTIONS's substitute URLs, rejecting unsafe untrusted overrides."
  (let-values (((text untrusted?) (options-substitute-urls options)))
    (if text
        (let ((urls (string-tokenize text)))
          (when (and untrusted?
                     (not (every (lambda (url)
                                   (define uri (string->uri url))
                                   (and uri (not (memq (uri-scheme uri) '(#f file)))))
                                 urls)))
            (error "unsafe or invalid substitute URLs" urls))
          urls)
        (substitute-urls))))

(define (lookup-substitutes options paths)
  "Query OPTIONS's caches for PATHS, returning authenticated narinfos for available paths."
  (lookup-narinfos/diverse (configured-substitute-urls options) paths valid-narinfo?))
