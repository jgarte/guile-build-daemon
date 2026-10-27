;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd references)
  #:use-module (gxd prelude)
  #:use-module ((gcrypt hash) #:select (open-sha256-port))
  #:use-module ((guix serialization) #:select (write-file))
  #:use-module ((rnrs bytevectors) #:select (bytevector-u8-ref))
  #:use-module ((rnrs io ports)
                #:select (make-custom-binary-output-port put-bytevector port-position))
  #:use-module ((srfi srfi-11) #:select (let-values))
  #:export (make-reference-matcher scan-nar))

(define base32-alphabet "0123456789abcdfghijklmnpqrsvwxyz")
(define reference-length 32)

(define (make-reference-matcher hashes)
  "Return two procedures: consume! and matched-hashes, searching for HASHES.
HASHES contains distinct 32-character Nix base32 hashes.  Call consume! with a
bytevector, offset and count, as a custom binary output port's write callback.
It consumes the slice and returns count; matches may span successive slices.
The caller may reuse the buffer afterward.  Call matched-hashes without
arguments to obtain the distinct hashes found so far, sorted by `string<?'."
  (define pending (make-hash-table))
  (define found '())
  (define window (make-string reference-length))
  (define window-length 0)

  (define (record-match!)
    (define hash (hash-ref pending window))
    (when hash
      (set! found (cons hash found))
      (hash-remove! pending window)))

  (define (consume-character! character)
    (if (string-index base32-alphabet character)
        (begin
          (if (= window-length reference-length)
              (string-copy! window 0 window 1 reference-length)
              (set! window-length (1+ window-length)))
          (string-set! window (1- window-length) character)
          (when (= window-length reference-length) (record-match!)))
        (set! window-length 0)))

  (define (consume! bytes start count)
    (do ((index start (1+ index)))
        ((= index (+ start count)) count)
      (consume-character! (integer->char (bytevector-u8-ref bytes index)))))

  (define (matched-hashes)
    (sort (list-copy found) string<?))

  (for-each (lambda (hash) (hash-set! pending hash hash)) hashes)
  (values consume! matched-hashes))

(define (index-candidates paths)
  "Index candidate PATHS by their 32-character basename hash.
Reject missing hashes and collisions: each matched hash must identify one path."
  (define hash->path (make-hash-table))

  (for-each
   (lambda (path)
     (let* ((name (basename path))
            (separator (string-index name #\-)))
       (unless (and separator (= separator reference-length))
         (error "bad reference" path))
       (define hash (substring name 0 separator))
       (when (hash-ref hash->path hash)
         (error "duplicate reference hash" path))
       (hash-set! hash->path hash path)))
   paths)
  hash->path)

(define (scan-nar path candidates)
  "Return three values: references, SHA-256 bytevector and size of PATH's NAR.
References are CANDIDATES whose hash appears in the archive bytes, sorted by
`string<?'.  CANDIDATES contains store paths with distinct 32-character Nix
base32 hashes.  File contents, filenames within directories and symlink target
strings contribute archive bytes; PATH's own basename does not."
  (define hash->path (index-candidates candidates))
  (define hashes (hash-map->list (lambda (hash _) hash) hash->path))

  (let-values (((consume! matched-hashes) (make-reference-matcher hashes))
               ((hash-port digest) (open-sha256-port)))
    (call-with-cleanup
     (lambda () (close-port hash-port))
     (lambda ()
       ;; Guix writes the NAR to this port.  Send each slice to both consumers
       ;; without collecting the archive in memory or serializing PATH twice.
       (define output
         (make-custom-binary-output-port
          "reference-scanner"
          (lambda (bytes start count)
            (put-bytevector hash-port bytes start count)
            (consume! bytes start count))
          #f #f #f))

       (call-with-cleanup
        (lambda () (close-port output))
        (lambda ()
          (write-file path output)
          ;; Both ports buffer writes.  Include the final buffered bytes before
          ;; obtaining the hash port's byte count and digest.
          (force-output output)
          (force-output hash-port)
          (define size (port-position hash-port))
          (define references
            (map (lambda (hash) (hash-ref hash->path hash)) (matched-hashes)))

          (values (sort references string<?) (digest) size)))))))
