;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd references)
  #:use-module ((rnrs bytevectors) #:select (bytevector-u8-ref))
  #:export (make-reference-matcher))

(define base32-alphabet "0123456789abcdfghijklmnpqrsvwxyz")
(define reference-length 32)

(define (extend-window window character)
  (string-append
   (if (= (string-length window) reference-length)
       (substring window 1)
       window)
   (string character)))

(define (make-reference-matcher hashes)
  "Return two procedures: consume! and matched-hashes, searching for HASHES.
HASHES contains distinct 32-character Nix base32 hashes.  Call consume! with a
bytevector, offset and count, as a custom binary output port's write callback.
It consumes the slice and returns count; matches may span successive slices.
The caller may reuse the buffer afterward.  Call matched-hashes without
arguments to obtain the distinct hashes found so far, sorted by `string<?'."
  (define pending (make-hash-table))
  (define found '())
  (define window "")

  (define (record-match!)
    (when (hash-ref pending window)
      (set! found (cons window found))
      (hash-remove! pending window)))

  (define (consume-character! character)
    (if (string-index base32-alphabet character)
        (begin
          (set! window (extend-window window character))
          (record-match!))
        (set! window "")))

  (define (consume! bytes start count)
    (do ((index start (1+ index)))
        ((= index (+ start count)) count)
      (consume-character! (integer->char (bytevector-u8-ref bytes index)))))

  (define (matched-hashes)
    (sort (list-copy found) string<?))

  (for-each (lambda (hash) (hash-set! pending hash #t)) hashes)
  (values consume! matched-hashes))
