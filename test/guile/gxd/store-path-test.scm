;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd store-path-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd store-path)
                #:select (text-path store-name-error-name leading-dot-name-error?
                                    invalid-character-name-error-character))
  #:use-module (gxd test-prelude))

(define-suite (store-path-tests)
  (test "store names allow empty strings and the accepted ASCII characters" ()
    (is (string? (text-path "/gnu/store" "" #vu8() '())))
    (is (string? (text-path "/gnu/store" "AZaz09+-._?=" #vu8() '()))))

  (test "invalid names report the rejected name and character" ()
    (let ((dot-error (capture-exception
                      (lambda () (text-path "/gnu/store" ".bad" #vu8() '()))))
          (slash-error (capture-exception
                        (lambda () (text-path "/gnu/store" "a/b" #vu8() '())))))

      (is (leading-dot-name-error? dot-error))
      (is (equal? ".bad" (store-name-error-name dot-error)))
      (is (equal? "a/b" (store-name-error-name slash-error)))
      (is (char=? #\/ (invalid-character-name-error-character slash-error))))))
