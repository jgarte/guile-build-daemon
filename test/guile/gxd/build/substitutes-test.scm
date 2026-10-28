;; SPDX-License-Identifier: GPL-3.0-or-later

(define-module (gxd build substitutes-test)
  #:use-module (gxd test-prelude)
  #:use-module (gxd build config)
  #:use-module (gxd build substitutes)
  #:use-module ((gxd test-database) #:select (call-with-empty-database))
  #:use-module ((guix scripts substitute) #:select (substitute-urls))
  #:use-module ((ares suitbl core) #:select (define-suite test is)))

(define-suite (substitute-tests)
  (test "disabled substitution does not access the database or network" ()
    (is (not (substitute-paths! #f '("unused")
                               (build-config #:use-substitutes? #f))))))
