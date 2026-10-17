;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

;; Per-directory local variables for gxd.
((nil
  . ((fill-column . 78)
     (tab-width . 8)))
 (emacs-lisp-mode
  . ((indent-tabs-mode . nil)))
 (scheme-mode
  . ((indent-tabs-mode . nil)

     ;; Common Scheme/Guile forms used throughout the daemon and harness.
     (eval . (put 'define* 'scheme-indent-function 'defun))
     (eval . (put 'define-public 'scheme-indent-function 'defun))
     (eval . (put 'lambda* 'scheme-indent-function 1))
     (eval . (put 'chain 'scheme-indent-function 1))
     (eval . (put 'match 'scheme-indent-function 1))
     (eval . (put 'match-lambda 'scheme-indent-function 0))
     (eval . (put 'match-lambda* 'scheme-indent-function 0))
     (eval . (put 'syntax-rules 'scheme-indent-function 1))
     (eval . (put 'syntax-case 'scheme-indent-function 2))
     (eval . (put 'catch 'scheme-indent-function 1))
     (eval . (put 'guard 'scheme-indent-function 1))
     (eval . (put 'let-values 'scheme-indent-function 1))
     (eval . (put 'parameterize 'scheme-indent-function 1))
     (eval . (put 'with-fluids 'scheme-indent-function 2))
     (eval . (put 'with-exception-handler 'scheme-indent-function 0))
     (eval . (put 'dynamic-wind 'scheme-indent-function 0))
     (eval . (put 'call-with-input-string 'scheme-indent-function 1))
     (eval . (put 'call-with-input-file 'scheme-indent-function 1))
     (eval . (put 'call-with-client 'scheme-indent-function 1))
     (eval . (put 'call-with-destination-lock 'scheme-indent-function 1))
     (eval . (put 'call-with-option-error-reporting 'scheme-indent-function 1))
     (eval . (put 'call-with-text-error-reporting 'scheme-indent-function 1))
     (eval . (put 'database:call-with-database 'scheme-indent-function 1))
     (eval . (put 'call-with-transaction 'scheme-indent-function 1))
     (eval . (put 'call-with-output-file 'scheme-indent-function 1))
     (eval . (put 'with-output-to-file 'scheme-indent-function 1))
     (eval . (put 'role-observes? 'scheme-indent-function 2))
     (eval . (put 'daemon-observes? 'scheme-indent-function 1))
     (eval . (put 'user-observes? 'scheme-indent-function 1))

     ;; Guix data forms used by the development manifests/packages.
     (eval . (put 'substitute-keyword-arguments 'scheme-indent-function 1))
     (eval . (put 'channel 'scheme-indent-function 0))
     (eval . (put 'git-reference 'scheme-indent-function 0))
     (eval . (put 'origin 'scheme-indent-function 0))
     (eval . (put 'package 'scheme-indent-function 0))

     ;; Suitbl DSL forms.
     (eval . (put 'suite 'scheme-indent-function 1))
     (eval . (put 'test 'scheme-indent-function 2))
     (eval . (put 'test-loader 'scheme-indent-function 2))
     (eval . (put 'suite-loader 'scheme-indent-function 1)))))
