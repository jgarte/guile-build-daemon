;;; Low-level worker protocol parsing primitives.
;;;
;;; Nix/Guix worker protocol has a few recurring wire-format rules that show up
;;; in almost every request/reply parser:
;;;
;;;   * integral values are sent as 8-byte little-endian fields;
;;;   * booleans are encoded as those integers (0 => #f, non-zero => #t);
;;;   * strings are encoded as:
;;;       [8-byte length][UTF-8 payload][zero padding to 8-byte boundary]
;;;   * lists are encoded as [8-byte count] followed by repeated elements.
;;;
;;; This module keeps those rules in one place so higher-level parsers can stay
;;; focused on protocol meaning instead of byte indexing mechanics.

(define-module (guix-gd daemon protocol primitives)
  #:use-module ((guix-gd daemon logging) #:select (summarise-bytevector))
  #:use-module (ice-9 format)
  #:use-module (rnrs bytevectors)
  #:export (slice-bytevector
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
            parse-string-pairs-at))

(define (slice-bytevector bv start count)
  "Return COUNT bytes copied from BV starting at START."
  (let ((out (make-bytevector count)))
    (bytevector-copy! bv start out 0 count)
    out))

(define (drop-bytevector-prefix bv count)
  "Return BV without its first COUNT bytes."
  (slice-bytevector bv count (- (bytevector-length bv) count)))

(define (append-bytevector-slice base chunk count)
  "Append the first COUNT bytes of CHUNK to BASE and return a fresh bytevector."
  (let* ((base-len (bytevector-length base))
         (out (make-bytevector (+ base-len count))))
    (bytevector-copy! base 0 out 0 base-len)
    (bytevector-copy! chunk 0 out base-len count)
    out))

(define (bytes-available? bv start count)
  "Return true when COUNT bytes can be read from BV starting at START."
  (>= (- (bytevector-length bv) start) count))

(define (parsed value next)
  "Pack parser VALUE with the NEXT unread byte index."
  (cons value next))

(define (parsed-value result)
  "Return the value part of parser RESULT."
  (car result))

(define (parsed-next result)
  "Return the next unread index from parser RESULT."
  (cdr result))

(define (parse-int-at bv start)
  "Parse one worker-protocol integer from BV at START.

The protocol field width is always eight bytes.  Most values in practice fit in
32 bits, but the parser supports non-zero high halves as well."
  (and (bytes-available? bv start 8)
       (let ((lo (bytevector-u32-ref bv start (endianness little)))
             (hi (bytevector-u32-ref bv (+ start 4) (endianness little))))
         (if (= hi 0)
             (parsed lo (+ start 8))
             (parsed (+ lo (ash hi 32)) (+ start 8))))))

(define (parse-longlong-at bv start)
  "Parse one little-endian 64-bit integer from BV at START."
  (and (bytes-available? bv start 8)
       (parsed (bytevector-u64-ref bv start (endianness little))
               (+ start 8))))

(define (parse-bool-at bv start)
  "Parse one worker-protocol boolean from BV at START."
  (let ((result (parse-int-at bv start)))
    (and result
         (parsed (not (= 0 (parsed-value result)))
                 (parsed-next result)))))

(define (padding-size len)
  "Return the wire padding used after a LEN-byte string payload.

Padding keeps the next field 8-byte aligned."
  (modulo (- 8 (modulo len 8)) 8))

(define (safe-utf8->string bv)
  "Decode BV as UTF-8, falling back to a readable placeholder on failure."
  (catch #t
    (lambda () (utf8->string bv))
    (lambda _
      (format #f "<non-utf8: ~a>"
              (summarise-bytevector bv (bytevector-length bv))))))

(define (parse-string-at bv start)
  "Parse one padded worker-protocol string from BV at START.

Expected layout: [len:int64][payload bytes][alignment padding]."
  (let ((len-result (parse-int-at bv start)))
    (and len-result
         (let* ((len (parsed-value len-result))
                (data-start (parsed-next len-result))
                (pad (padding-size len))
                (need (+ len pad)))
           (and (bytes-available? bv data-start need)
                (parsed (safe-utf8->string (slice-bytevector bv data-start len))
                        (+ data-start need)))))))

(define (parse-string-list-at bv start)
  "Parse one worker-protocol list of strings from BV at START."
  (let ((count-result (parse-int-at bv start)))
    (and count-result
         (let loop ((remaining (parsed-value count-result))
                    (index (parsed-next count-result))
                    (items '()))
           (if (= remaining 0)
               (parsed (reverse items) index)
               (let ((item-result (parse-string-at bv index)))
                 (and item-result
                      (loop (- remaining 1)
                            (parsed-next item-result)
                            (cons (parsed-value item-result) items)))))))))

(define (parse-string-pairs-at bv start)
  "Parse one worker-protocol list of string pairs from BV at START."
  (let ((count-result (parse-int-at bv start)))
    (and count-result
         (let loop ((remaining (parsed-value count-result))
                    (index (parsed-next count-result))
                    (items '()))
           (if (= remaining 0)
               (parsed (reverse items) index)
               (let ((first-result (parse-string-at bv index)))
                 (and first-result
                      (let ((second-result
                             (parse-string-at bv (parsed-next first-result))))
                        (and second-result
                             (loop (- remaining 1)
                                   (parsed-next second-result)
                                   (cons (cons (parsed-value first-result)
                                               (parsed-value second-result))
                                         items)))))))))))
