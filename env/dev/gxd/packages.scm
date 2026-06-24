(define-module (gxd packages)
  #:use-module (gxd channels)                     ; provides `gxd-channels`
  #:use-module (guix packages)                    ; provides `package`
  #:use-module (gnu packages bash)                ; provides `bash-minimal`
  #:use-module (gnu packages guile)               ; provides `guile-3.0`
  #:use-module (guix build utils)                 ; provides `modify-phases`
  #:use-module (guix build-system trivial)        ; provides `trivial-build-system`
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix gexp))

(define-public gxd
  (package
    (name "gxd")
    (version "0.1.0")
     (source
      ;; Daemon modules packaged as an executable command.
      ;; Path is relative to repository root.
      (local-file "src/gxd"
                  "gxd"
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
                 (module-dir (string-append site-root "/gxd"))
                 (wrapper (string-append bin "/gxd"))
                 (guile (string-append #$(this-package-input "guile") "/bin/guile"))
                 (sh (string-append #$(this-package-input "bash-minimal") "/bin/sh")))
            (mkdir-p bin)
            (mkdir-p module-dir)
            ;; Install modules under gxd/*.scm.
            (copy-recursively #$source module-dir)
            ;; CLI wrapper: import module and run (main (command-line)).
            (with-output-to-file wrapper
              (lambda ()
                (format #t
                        "#!~a~%exec ~a -L ~a -c '(use-modules (gxd main)) (main (command-line))' \"$@\"~%"
                        sh guile site-root)))
            (chmod wrapper #o555)))))
    (home-page "https://codeberg.org/cons-town/guile-build-daemon")
    (synopsis "Guile relay and protocol logger for the Guix daemon")
    (description
     "This package installs the @command{gxd} command, which listens on a
 UNIX socket, relays the worker protocol to a fallback @command{guix-daemon},
 and logs the exchanged calls and payloads for protocol debugging.")
    (license license:gpl3+)))
