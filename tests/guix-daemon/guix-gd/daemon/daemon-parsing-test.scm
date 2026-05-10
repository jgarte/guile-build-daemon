;; SPDX-License-Identifier: GPL-3.0-or-later
;; Parsing primitive tests for (guix-gd daemon).

(define-module (guix-gd daemon-parsing-test)
  #:use-module (ares suitbl core)
  #:use-module ((ares suitbl runner) #:prefix runner:)
  #:use-module ((ares suitbl reporters) #:prefix reporter:)
  #:use-module ((ares suitbl state) #:prefix state:)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:export (run-daemon-parser-tests
            daemon-parser-tests))

;; Access non-exported parser primitives from (guix-gd daemon).
(define parse-int-at (@@ (guix-gd daemon daemon) parse-int-at))
(define parse-longlong-at (@@ (guix-gd daemon daemon) parse-longlong-at))
(define parse-bool-at (@@ (guix-gd daemon daemon) parse-bool-at))
(define parse-string-at (@@ (guix-gd daemon daemon) parse-string-at))
(define parse-string-list-at (@@ (guix-gd daemon daemon) parse-string-list-at))
(define parse-string-pairs-at (@@ (guix-gd daemon daemon) parse-string-pairs-at))
(define padding-size (@@ (guix-gd daemon daemon) padding-size))
(define parsed-value (@@ (guix-gd daemon daemon) parsed-value))
(define parsed-next (@@ (guix-gd daemon daemon) parsed-next))

(define (bv-append . bvs)
  (let ((len (apply + (map bytevector-length bvs))))
    (let loop ((rest bvs) (offset 0) (out (make-bytevector len)))
      (match rest
        (() out)
        ((head . tail)
         (bytevector-copy! head 0 out offset (bytevector-length head))
         (loop tail (+ offset (bytevector-length head)) out))))))

(define (wire-int n)
  (let ((bv (make-bytevector 8 0)))
    (bytevector-u32-set! bv 0 n (endianness little))
    bv))

(define (wire-int/hi lo hi)
  (let ((bv (make-bytevector 8 0)))
    (bytevector-u32-set! bv 0 lo (endianness little))
    (bytevector-u32-set! bv 4 hi (endianness little))
    bv))

(define (wire-longlong n)
  (let ((bv (make-bytevector 8 0)))
    (bytevector-u64-set! bv 0 n (endianness little))
    bv))

(define (wire-bytes payload)
  (let* ((len (bytevector-length payload))
         (pad (padding-size len)))
    (bv-append (wire-int len)
               payload
               (make-bytevector pad 0))))

(define (wire-string s)
  (wire-bytes (string->utf8 s)))

(define (wire-string-list strings)
  (apply bv-append
         (wire-int (length strings))
         (map wire-string strings)))

(define-suite daemon-parser-tests
  (suite "integer primitives"
    (test "parse-int-at 32-bit"
      (let ((r (parse-int-at (wire-int #x12345678) 0)))
        (is (= #x12345678 (parsed-value r)))
        (is (= 8 (parsed-next r)))))

    (test "parse-int-at with high 32 bits"
      (let ((r (parse-int-at (wire-int/hi #x01020304 1) 0)))
        (is (= (+ #x01020304 (ash 1 32)) (parsed-value r)))
        (is (= 8 (parsed-next r)))))

    (test "parse-int-at needs full 8 bytes"
      (is (not (parse-int-at (make-bytevector 7 0) 0))))

    (test "parse-longlong-at"
      (let ((r (parse-longlong-at (wire-longlong #x0102030405060708) 0)))
        (is (= #x0102030405060708 (parsed-value r)))
        (is (= 8 (parsed-next r)))))

    (test "parse-bool-at"
      (is (parsed-value (parse-bool-at (wire-int 1) 0)))
      (is (not (parsed-value (parse-bool-at (wire-int 0) 0))))))

  (suite "string primitives"
    (test "padding-size"
      (is (= 0 (padding-size 0)))
      (is (= 7 (padding-size 1)))
      (is (= 0 (padding-size 8)))
      (is (= 1 (padding-size 15))))

    (test "parse-string-at UTF-8"
      (let ((r (parse-string-at (wire-string "hello") 0)))
        (is (string=? "hello" (parsed-value r)))
        (is (= 16 (parsed-next r)))))

    (test "parse-string-at non UTF-8 fallback"
      (let* ((payload (u8-list->bytevector '(255 254 253)))
             (r (parse-string-at (wire-bytes payload) 0)))
        (is (string-contains (parsed-value r) "<non-utf8:"))))

    (test "parse-string-list-at"
      (let ((r (parse-string-list-at (wire-string-list '("a" "bb" "ccc")) 0)))
        (is (= 3 (length (parsed-value r))))
        (is (equal? '("a" "bb" "ccc") (parsed-value r)))))

    (test "parse-string-pairs-at"
      (let* ((wire (bv-append (wire-int 2)
                              (wire-string "root1") (wire-string "target1")
                              (wire-string "root2") (wire-string "target2")))
             (r (parse-string-pairs-at wire 0)))
        (is (= 2 (length (parsed-value r))))
        (is (equal? '(("root1" . "target1")
                      ("root2" . "target2"))
                    (parsed-value r)))))))

(define (run-daemon-parser-tests)
  (let ((runner-instance
         (runner:make-suitbl
          #:config `((test-reporter . ,reporter:silent)
                     (auto-run? . #t)
                     (re-raise? . #t)))))
    (with-test-runner
     runner-instance
     (daemon-parser-tests)
     (let* ((state (runner:get-state runner-instance))
            (summary (or (state:get-run-summary state)
                         '((tests . 0)
                           (failures . 0)
                           (errors . 0)
                           (skipped . 0)
                           (assertions . 0)))))
       (when (> (or (assoc-ref summary 'failures) 0) 0)
         (error "daemon parser tests failed" summary))
       summary))))
