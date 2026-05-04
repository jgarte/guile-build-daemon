;;; Logging and byte-preview helpers for the Guix daemon relay.

(define-module (guix-gd daemon logging)
  #:use-module (guix-gd daemon constants)
  #:use-module (ice-9 format)       ; format
  #:use-module (rnrs bytevectors)   ; bytevector-u8-ref
  #:use-module (rnrs io ports)      ; force-output
  #:use-module (srfi srfi-1)        ; iota
  #:use-module (srfi srfi-13)       ; string-join, string-take
  #:export (log
            byte->hex
            byte->ascii
            string-preview
            summarise-bytevector
            details->string))

(define (log fmt . args)
  "Write one flushed log message.

Explicit flushing matters because two relay threads log concurrently and the
messages are most useful while the connection is still live."
  (apply format #t fmt args)
  (force-output))

(define (byte->hex n)
  "Render byte N as two lowercase hex digits."
  (format #f "~2,'0x" n))

(define (byte->ascii n)
  "Render byte N as printable ASCII, or `.` for control bytes."
  (if (and (>= n 32) (<= n 126))
      (string (integer->char n))
      "."))

(define (string-preview s)
  "Return a compact one-line preview of S for logs."
  (let* ((normalised
          (list->string
           (map (lambda (ch)
                  (if (or (char=? ch #\newline)
                          (char=? ch #\return)
                          (char=? ch #\tab))
                      #\space
                      ch))
                (string->list s))))
         (trimmed (if (> (string-length normalised) string-preview-limit)
                      (string-append (string-take normalised string-preview-limit)
                                     "...")
                      normalised)))
    (format #f "~s" trimmed)))

(define (summarise-bytevector bv n)
  "Return a short hex plus ASCII preview of the first N bytes in BV."
  (let* ((limit (min n preview-limit))
         (hex (string-join
               (map (lambda (i) (byte->hex (bytevector-u8-ref bv i)))
                    (iota limit))
               " "))
         (ascii (string-join
                 (map (lambda (i) (byte->ascii (bytevector-u8-ref bv i)))
                      (iota limit))
                 "")))
    ;; (if (> n limit)
    ;;     (format #f "~a ... |~a|" hex ascii)
    ;;     (format #f "~a |~a|" hex ascii))
    (format #f "~a" ascii)))

(define (details->string details)
  "Render DETAILS compactly for structured operation logs."
  (if (null? details)
      ""
      (format #f " ~s" details)))
