;;; Constants for the Guix daemon 

(define-module (gxd protocol constants)
  #:export (WORKER_MAGIC_1
            WORKER_MAGIC_2
            PROTOCOL_VERSION
            STDERR_NEXT
            STDERR_READ
            STDERR_WRITE
            STDERR_LAST
            STDERR_ERROR))

;; defined in `worker-protocol.hh`

(define WORKER_MAGIC_1 #x6e697863)      ; ASCII: "nixc"
(define WORKER_MAGIC_2 #x6478696f)      ; ASCII: "dxio" (alternate/historical magic, not used)

(define PROTOCOL_VERSION #x0164)        ; v1.100  (high bytes = major, low byte = minor)


;; daemon control frames sent before normal operation reply payloads.

;; control frame type NEXT — carries a string message (the parser treats it as a next MESSAGE frame)
(define STDERR_NEXT  #x6f6c6d67)        ; ASCII: "olmg"  

;; READ — request for data from the source (comment: "data needed from source").
(define STDERR_READ  #x64617461)        ; ASCII: "data"  

;; WRITE — indicates a following length + raw payload (data for sink).
(define STDERR_WRITE #x64617416)        ; ASCII: "dat\x16" (final byte is 0x16, a control byte)

;; LAST — end of the daemon control frames; after this comes the operation‑specific reply payload.
(define STDERR_LAST  #x616c7473)        ; ASCII: "alts"

;; ERROR — carries an error string and (for newer protocol minors) an integer status code.
(define STDERR_ERROR #x63787470)        ; ASCII: "cxtp"
