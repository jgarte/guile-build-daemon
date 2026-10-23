;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd build environment-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd build environment) #:select (build-environment))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((guix derivations)
                #:select (derivation-builder-environment-vars))
  #:use-module ((guix utils) #:select (with-environment-variables))
  #:use-module ((srfi srfi-9 gnu) #:select (set-fields)))

(define-suite (build-environment-tests)
  (test "derivation bindings override defaults but not the build directory" ()
    (let* ((drv
            (set-fields (empty-derivation)
              ((derivation-builder-environment-vars)
               '(("CUSTOM" . "kept")
                 ("NIX_BUILD_TOP" . "wrong")
                 ("PATH" . "/drv-path")
                 ("PWD" . "wrong")
                 ("TEMP" . "wrong")
                 ("TEMPDIR" . "wrong")
                 ("TMP" . "wrong")
                 ("TMPDIR" . "wrong")))))
           (expected-env
            '(("CUSTOM" . "kept")
              ("HOME" . "/homeless-shelter")
              ("NIX_BUILD_CORES" . "3")
              ("NIX_BUILD_TOP" . "/build")
              ("NIX_STORE" . "/store")
              ("PATH" . "/drv-path")
              ("PWD" . "/build")
              ("TEMP" . "/build")
              ("TEMPDIR" . "/build")
              ("TMP" . "/build")
              ("TMPDIR" . "/build")))
           (actual-env
            (with-environment-variables
             '(("GXD_INHERITED_CANARY" "must-not-enter-builder"))
             (build-environment drv "/store" "/build" 3))))

      (is (equal? expected-env actual-env)
          "only defaults, derivation bindings and actual build-directory variables remain"))))
