;;; Worker protocol façade.
;;;
;;; The protocol implementation is intentionally split into focused modules:
;;;
;;;   - (gxd protocol primitives)
;;;       Wire-format building blocks (int/string/list parsers)
;;;   - (gxd protocol client)
;;;       Client request opcode dispatch + payload parsers
;;;   - (gxd protocol daemon)
;;;       Daemon STDERR_* control-frame parser
;;;   - (gxd protocol reply)
;;;       Operation reply payload parsers
;;;
;;; This façade keeps the old module path `(gxd protocol)` stable for
;;; existing callers while exposing the same public API as before.

(define-module (gxd protocol)
  #:use-module (gxd protocol primitives)
  #:use-module (gxd protocol client)
  #:use-module (gxd protocol daemon)
  #:use-module (gxd protocol reply)
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
