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
     (eval . (put 'dynamic-wind 'scheme-indent-function 0))
     (eval . (put 'call-with-input-string 'scheme-indent-function 1))
     (eval . (put 'call-with-input-file 'scheme-indent-function 1))
     (eval . (put 'call-with-output-file 'scheme-indent-function 1))
     (eval . (put 'with-output-to-file 'scheme-indent-function 1))

     ;; Guix data forms used by the development manifests/packages.
     (eval . (put 'channel 'scheme-indent-function 0))
     (eval . (put 'git-reference 'scheme-indent-function 0))
     (eval . (put 'origin 'scheme-indent-function 0))
     (eval . (put 'package 'scheme-indent-function 0))

     ;; Suitbl DSL forms.
     (eval . (put 'define-suite 'scheme-indent-function 1))
     (eval . (put 'suite 'scheme-indent-function 1))
     (eval . (put 'test 'scheme-indent-function 1))
     (eval . (put 'with-test-runner 'scheme-indent-function 1)))))
