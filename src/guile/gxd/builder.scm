;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd builder)
  #:use-module (gxd prelude)
  #:use-module ((gxd build-environment) #:select (build-environment))
  #:use-module ((gxd builder-process)
                #:select (call-with-builder-process builder-output wait-builder!))
  #:use-module ((guix derivations)
                #:select (derivation-builder derivation-builder-arguments))
  #:use-module ((rnrs bytevectors) #:select (u8-list->bytevector utf8->string))
  #:use-module ((rnrs io ports) #:select (get-u8 get-bytevector-some))
  #:export (execute-builder!))

(define (read-setup-line output)
  "Consume one newline-terminated setup line from binary OUTPUT; return its bytes.
Raise on EOF before newline.  Leave subsequent builder log bytes untouched."
  (let loop ((bytes '()))
    (define byte (get-u8 output))
    (cond
     ((eof-object? byte) (error "unexpected EOF reading builder setup line"))
     ((= byte (char->integer #\newline))
      (u8-list->bytevector (reverse bytes)))
     (else (loop (cons byte bytes))))))

(define (check-builder-setup! output)
  "Consume the setup line from OUTPUT: empty means success, otherwise raise its diagnostic."
  (define diagnostic (utf8->string (read-setup-line output)))

  (unless (string-null? diagnostic)
    (error diagnostic)))

(define (forward-builder-output! output log!)
  (let loop ()
    (define bytes (get-bytevector-some output))
    (unless (eof-object? bytes)
      (log! bytes)
      (loop))))

(define (execute-builder! drv store-directory build-directory cores log!)
  "Execute DRV with an environment built from STORE-DIRECTORY, BUILD-DIRECTORY and CORES.
Pass binary output chunks to LOG! after checking setup; return the raw wait status.
The caller owns BUILD-DIRECTORY.  Outputs are not validated or registered."
  (define environment (build-environment drv store-directory build-directory cores))

  (call-with-builder-process
   (derivation-builder drv) (derivation-builder-arguments drv)
   environment build-directory
   (lambda (process)
     (define output (builder-output process))
     (check-builder-setup! output)
     (forward-builder-output! output log!)
     (wait-builder! process))))
