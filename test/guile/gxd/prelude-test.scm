;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd prelude-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module (gxd test-prelude))

(define nested
  '((a . 1)
    (b . ((c . 2)
          (d . ((e . 3)))))))

(define-suite (get-tests)
  (test "get reads a key, or #f when it is absent" ()
    (is (= 1 (get nested 'a)))
    (is (eq? #f (get nested 'missing))))

  (test "get-in returns the value under a path" ()
    (is (= 2 (get-in nested '(b c))))
    (is (= 3 (get-in nested '(b d e))))
    (is (equal? nested (get-in nested '()))))

  (test "get-in returns #f when a path leads nowhere" ()
    (is (eq? #f (get-in nested '(missing))))
    (is (eq? #f (get-in nested '(b missing))))
    (is (eq? #f (get-in nested '(b d e missing))))
    (is (eq? #f (get-in nested '(a b))))))
