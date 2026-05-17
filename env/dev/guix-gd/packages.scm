(define-module (guix-gd packages)
  #:use-module (guix-gd channels)                 ; provides `guix-gd-channels`
  #:use-module (guix packages)                    ; provides `package`
  #:use-module (gnu packages package-management)  ; provides `guix` & `guix-daemon`
  #:use-module (gnu packages bash)                ; provides `bash-minimal`
  #:use-module (gnu packages guile)               ; provides `guile-3.0`
  #:use-module (guix utils)                       ; provides `substitute-keyword-arguments`
  #:use-module (guix channels)                    ; provides `guix-channel?`
  #:use-module (guix build utils)                 ; provides `modify-phases`
  #:use-module (srfi srfi-1)                      ; provides `find`, etc.
  #:use-module (guix build-system channel)        ; provides `channel-build-system`
  #:use-module (guix build-system trivial)        ; provides `trivial-build-system`
  #:use-module (guix git-download)                ; provides `git-fetch`, `git-reference`
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix gexp))

(define-public guix-gd-daemon
  (package
    (name "guix-gd-daemon")
    (version "0.1.0")
    (source
     ;; Local development modules to package as an executable command.
     ;; Path is relative to repository root (development use).
     (local-file "dev/guix-daemon/guix-gd/daemon"
                 "daemon"
                 #:recursive? #t))
    (build-system trivial-build-system)
    (inputs (list guile-3.0 bash-minimal))
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out #$output)
                 (bin (string-append out "/bin"))
                 (site-root (string-append out "/share/guile/site/3.0"))
                 (site (string-append site-root "/guix-gd"))
                 (daemon-module-dir (string-append site "/daemon"))
                 (wrapper (string-append bin "/guix-gd-daemon"))
                 (guile (string-append #$(this-package-input "guile") "/bin/guile"))
                 (sh (string-append #$(this-package-input "bash-minimal") "/bin/sh")))
            (mkdir-p bin)
            (mkdir-p site)
            ;; Install daemon modules under guix-gd/daemon/*.scm.
            (copy-recursively #$source daemon-module-dir)
            ;; CLI wrapper: import module and run (main (command-line)).
            (with-output-to-file wrapper
              (lambda ()
                (format #t
                        "#!~a~%exec ~a -L ~a -c '(use-modules (guix-gd daemon daemon)) (main (command-line))' \"$@\"~%"
                        sh guile site-root)))
            (chmod wrapper #o555)))))
    (home-page "https://codeberg.org/cons-town/guile-build-daemon")
    (synopsis "Development Guile script that mimics the Guix daemon protocol")
    (description
     "This package installs the @command{guix-gd-daemon} command, which starts
 a local development Guile script implementing a minimal fake Guix daemon
 listener for protocol debugging.")
    (license license:gpl3+)))

