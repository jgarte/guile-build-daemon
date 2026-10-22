;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd references-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd references) #:select (make-reference-matcher scan-nar))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((rnrs bytevectors)
                #:select (string->utf8 make-bytevector bytevector-length bytevector-u8-set!
                                       bytevector=?))
  #:use-module ((srfi srfi-11) #:select (let-values)))

(define-suite (reference-matcher-tests)
  (test "find overlapping candidate hashes once, excluding other hashes and surrounding binary bytes" ()
    (let* ((first-hash (make-string 32 #\a))
           (second-hash (string-append (make-string 31 #\a) "b"))
           (other-hash (make-string 32 #\c))
           (expected-hashes (list first-hash second-hash))
           (bytes (string->utf8
                   (string-append "\x00" first-hash "b\xff" other-hash first-hash))))
      (let-values (((consume! matched-hashes) (make-reference-matcher (list second-hash first-hash))))
        (consume! bytes 0 (bytevector-length bytes))

        (is (equal? expected-hashes (matched-hashes))))))

  (test "find a hash split across successive one-byte writes" ()
    (let* ((hash (make-string 32 #\a))
           (expected-hashes (list hash))
           (bytes (make-bytevector 3 0)))
      (let-values (((consume! matched-hashes) (make-reference-matcher (list hash))))
        (do ((index 0 (1+ index))) ((= index 32))
          (bytevector-u8-set! bytes 1 (char->integer #\a))
          (consume! bytes 1 1)
          ;; Simulate the writer reusing its buffer after the callback returns.
          (bytevector-u8-set! bytes 1 0))

        (is (equal? expected-hashes (matched-hashes)))))))

(define (reference-path hash)
  (string-append "/store/" hash "-candidate"))

(define-suite (reference-scanner-tests)
  (test "find references in a file, a filename and a symlink target" ()
    (call-with-temporary-directory
     (lambda (directory)
       (let* ((content-hash (make-string 32 #\a))
              (name-hash (make-string 32 #\b))
              (target-hash (make-string 32 #\c))
              (absent-hash (make-string 32 #\d))

              (expected-references
               (map reference-path (list content-hash name-hash target-hash)))
              (candidates (cons (reference-path absent-hash) expected-references)))

         (spit (string-append directory "/contents") content-hash)
         (spit (string-append directory "/" name-hash) "")
         (symlink target-hash (string-append directory "/link"))

         (let-values (((found-references actual-hash actual-size) (scan-nar directory candidates))
                      ((expected-hash expected-size) (nar-sha256 directory)))
           (is (equal? expected-references found-references)
               "contents, filename and stored symlink target each contribute their reference")
           (is (bytevector=? expected-hash actual-hash))
           (is (= expected-size actual-size)))))))

  (test "a file does not reference itself merely because its name contains its hash" ()
    (call-with-temporary-directory
     (lambda (directory)
       (let* ((hash (make-string 32 #\a))
              (path (string-append directory "/" hash "-output")))
         (spit path "no references")

         (let-values (((found-references actual-hash actual-size)
                       (scan-nar path (list path)))
                      ((expected-hash expected-size) (nar-sha256 path)))
           (is (null? found-references))
           (is (bytevector=? expected-hash actual-hash))
           (is (= expected-size actual-size))))))))
