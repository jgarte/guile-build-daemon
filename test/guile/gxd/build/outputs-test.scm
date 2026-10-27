;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build outputs-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd build outputs)
                #:select (prepare-output! missing-output-error-drv-path missing-output-error-output-path
                          output-permission-error-output-path))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((guix store deduplication) #:select (nar-sha256))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?))
  #:use-module ((srfi srfi-11) #:select (let-values)))

(define dummy-drv-path "/store/example.drv")

(define-suite (build-output-tests)
  (test "reject a missing output with the derivation and output paths" ()
    (call-with-temporary-directory
     (lambda (directory)
       (let* ((drv-path dummy-drv-path)
              (output-path (string-append directory "/missing"))
              (actual-exception
               (capture-exception
                (lambda () (prepare-output! drv-path output-path (list output-path))))))
         (is (equal? drv-path (missing-output-error-drv-path actual-exception)))
         (is (equal? output-path (missing-output-error-output-path actual-exception)))))))

  (test "reject a group-writable output before changing its metadata" ()
    (call-with-temporary-directory
     (lambda (directory)
       (define output-path (string-append directory "/" (make-string 32 #\b) "-output"))
       (spit output-path "output")
       (chmod output-path #o660)
       (utime output-path 123 456)
       (define original-stats (lstat output-path))

       (define actual-exception
         (capture-exception
          (lambda () (prepare-output! dummy-drv-path output-path (list output-path)))))

       (is (equal? output-path (output-permission-error-output-path actual-exception)))
       (is (= (stat:perms original-stats) (stat:perms (lstat output-path))))
       (is (= (stat:mtime original-stats) (stat:mtime (lstat output-path)))))))

  (test "canonicalize an output and return its reference, NAR hash and size" ()
    (call-with-temporary-directory
     (lambda (directory)
       (let* ((output-path (string-append directory "/" (make-string 32 #\b) "-output"))
              (reference-hash (make-string 32 #\a))
              (reference-path (string-append "/store/" reference-hash "-input"))
              (expected-references (list reference-path)))
         (spit output-path reference-hash)
         (chmod output-path #o600)
         (utime output-path 123 456)

         (let-values (((found-references actual-hash actual-size)
                       (prepare-output! dummy-drv-path output-path
                                        (cons output-path expected-references)))
                      ((expected-hash expected-size) (nar-sha256 output-path)))
           (is (= #o444 (stat:perms (lstat output-path))))
           (is (= 1 (stat:mtime (lstat output-path))))
           (is (equal? expected-references found-references))
           (is (bytevector=? expected-hash actual-hash))
           (is (= expected-size actual-size)))))))

  (test "accept a symlink output without changing its target" ()
    (call-with-temporary-directory
     (lambda (directory)
       (let ((output-path (string-append directory "/" (make-string 32 #\b) "-output"))
             (target-path (string-append directory "/target")))
         (spit target-path "target")
         (chmod target-path #o600)
         (utime target-path 123 456)
         (symlink target-path output-path)
         (define original-target-stats (lstat target-path))
         (prepare-output! dummy-drv-path output-path (list output-path))

         (is (= 1 (stat:mtime (lstat output-path))))
         (is (= (stat:perms original-target-stats) (stat:perms (lstat target-path))))
         (is (= (stat:mtime original-target-stats) (stat:mtime (lstat target-path)))))))))
