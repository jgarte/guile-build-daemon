;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build execution)
  #:use-module (gxd prelude)
  #:use-module ((gxd build environment) #:select (build-environment))
  #:use-module ((gxd build process)
                #:select (call-with-builder-process builder-output wait-builder!))
  #:use-module ((gxd build sandbox) #:select (sandbox-build-directory))
  #:use-module ((guix derivations)
                #:select (derivation-builder derivation-builder-arguments))
  #:use-module ((rnrs bytevectors) #:select (u8-list->bytevector utf8->string))
  #:use-module ((rnrs io ports) #:select (get-u8 get-bytevector-some))
  #:export (execute-program! execute-builder!))

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

(define* (execute-program! program arguments environment build-directory log!
                           #:optional (sandbox #f))
  "Run PROGRAM with ARGUMENTS and ENVIRONMENT, delivering binary output to LOG!.
Return the raw wait status.  The caller owns BUILD-DIRECTORY.
With SANDBOX, run inside its prepared filesystem; otherwise run on the host."
  (call-with-builder-process
   program arguments environment build-directory sandbox
   (lambda (process)
     (define output (builder-output process))
     (check-builder-setup! output)
     (forward-builder-output! output log!)
     (wait-builder! process))))

(define* (execute-builder! drv store-directory build-directory cores log!
                           #:optional (sandbox #f))
  "Execute DRV with an environment built from STORE-DIRECTORY, BUILD-DIRECTORY and CORES.
Pass binary output chunks to LOG! after checking setup; return the raw wait status.
The caller owns host workspace BUILD-DIRECTORY.  With SANDBOX, use its build
directory in the environment and execute within its prepared filesystem.
Outputs are not validated or registered."
  (define environment
    (build-environment drv store-directory
                       (if sandbox (sandbox-build-directory sandbox) build-directory) cores))

  (execute-program!
   (derivation-builder drv) (derivation-builder-arguments drv)
   environment build-directory log! sandbox))
