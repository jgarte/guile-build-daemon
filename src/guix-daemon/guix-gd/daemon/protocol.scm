;;; Worker protocol façade.
;;;
;;; The protocol implementation is intentionally split into focused modules:
;;;
;;;   - (guix-gd daemon protocol primitives)
;;;       Wire-format building blocks (int/string/list parsers)
;;;   - (guix-gd daemon protocol client)
;;;       Client request opcode dispatch + payload parsers
;;;   - (guix-gd daemon protocol daemon)
;;;       Daemon STDERR_* control-frame parser
;;;   - (guix-gd daemon protocol reply)
;;;       Operation reply payload parsers
;;;
;;; This façade keeps the old module path `(guix-gd daemon protocol)` stable for
;;; existing callers while exposing the same public API as before.

(define-module (guix-gd daemon protocol)
  #:use-module (guix-gd daemon protocol primitives)
  #:use-module (guix-gd daemon protocol client)
  #:use-module (guix-gd daemon protocol daemon)
  #:use-module (guix-gd daemon protocol reply)
  #:re-export (slice-bytevector
               drop-bytevector-prefix
               append-bytevector-slice
               bytes-available?
               parsed
               parsed-value
               parsed-next
               parse-int-at
               parse-longlong-at
               parse-bool-at
               padding-size
               safe-utf8->string
               parse-string-at
               parse-string-list-at
               parse-string-pairs-at
               op-name
               parse-client-operation-at
               parse-daemon-frame-at
               parse-current-op-reply-at))
