;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd test-prelude-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((gxd test-prelude)
                #:select (capture-exception with-module-bindings)))

(define first 'original-first)
(define second 'original-second)

(define-suite (with-module-bindings-tests)
  (test "temporary module bindings are visible and then restored" ()
    (define module (resolve-module '(gxd test-prelude-test)))
    (define during
      (with-module-bindings module
                            '((first . temporary-first) (second . temporary-second))
                            (lambda ()
                              (list (module-ref module 'first)
                                    (module-ref module 'second)))))

    (is (equal? '(temporary-first temporary-second) during))
    (is (eq? 'original-first (module-ref module 'first)))
    (is (eq? 'original-second (module-ref module 'second))))

  (test "temporary module bindings are restored after an exception" ()
    (define module (resolve-module '(gxd test-prelude-test)))
    (define captured
      (capture-exception
       (lambda ()
         (with-module-bindings module '((first . temporary-first))
                               (lambda () (error "expected failure"))))))

    (is captured)
    (is (eq? 'original-first (module-ref module 'first)))))
