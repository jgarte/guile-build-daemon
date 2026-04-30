;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(use-modules (ares server)
             (ares reflection metadata)
             (fibers)
             (ice-9 exceptions))

;; Work around crashes on some systems (exit 137) during metadata
;; extraction used by lookup/completion.
(define metadata-module (resolve-module '(ares reflection metadata)))

(module-set! metadata-module
             'get-docstring
             (lambda (_var)
               ""))

(module-set! metadata-module
             'get-arglists
             (lambda (_var)
               #()))

;; Keep one crashing client from taking down the whole server.
(define (safe-on-connection client id thunk)
  (spawn-fiber
   (lambda ()
     (with-exception-handler
      (lambda (ex)
        (format (current-error-port)
                "Ares client ~a crashed: ~a~%" id ex)
        (false-if-exception (close-port client)))
      thunk
      #:unwind? #t))))

(run-nrepl-server #:on-connection safe-on-connection)
