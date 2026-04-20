(define-module (guix-gd packages)
  #:use-module (guix-gd config)                   ; provides `guix-gd-root` and `guix-gd-group`
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
     ;; Local development module to package as an executable command.
     ;; Path is relative to repository root (development use).
     (local-file "dev/guix-daemon/guix-gd/daemon/daemon.scm"
                 "daemon.scm"))
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
                 (module-file (string-append site "/daemon.scm"))
                 (wrapper (string-append bin "/guix-gd-daemon"))
                 (guile (string-append #$(this-package-input "guile") "/bin/guile"))
                 (sh (string-append #$(this-package-input "bash-minimal") "/bin/sh")))
            (mkdir-p bin)
            (mkdir-p site)
            ;; Install module as (guix-gd daemon).
            (copy-file #$source module-file)
            ;; CLI wrapper: import module and run (main (command-line)).
            (with-output-to-file wrapper
              (lambda ()
                (format #t
                        "#!~a~%exec ~a -L ~a -c '(use-modules (guix-gd daemon)) (main (command-line))' \"$@\"~%"
                        sh guile site-root)))
            (chmod wrapper #o555)))))
    (home-page "https://codeberg.org/cons-town/guile-build-daemon")
    (synopsis "Development Guile script that mimics the Guix daemon protocol")
    (description
     "This package installs the @command{guix-gd-daemon} command, which starts
 a local development Guile script implementing a minimal fake Guix daemon
 listener for protocol debugging.")
    (license license:gpl3+)))

(define-public guix-gd-fallback
  (let* ((name "guix-gd-fallback")
         (guix-channel (find guix-channel? guix-gd-channels))
         (commit (channel-commit guix-channel))
         (url (channel-url guix-channel)))
    (package
     (inherit guix)
     (name name)
     (version
      (string-append (car (string-split (package-version guix) #\-))
                     "-" (string-take commit 7)))
     ;; use guix source from pinned guix channel
     (source (origin
              (method git-fetch)
              (uri (git-reference (url url) (commit commit)))
              (sha256
               (base32
                "18wdn43wpqz7gz142w79iysq2xp8nd4nszamkpnjh61gy2p58bw4"))
              (file-name (string-append "guix-" version "-checkout"))))
     (arguments
      (substitute-keyword-arguments
       (package-arguments guix)
       ((#:channels channels) #~(remove guix-channel? #$channels))
       ;; Skip tests to save time.
       ((#:tests? tests? #f) #f)
       ;; ((#:imported-modules modules '()) `((guix-gd build-utils) ,@modules))
       ;; ((#:modules modules '()) `((guix-gd build-utils) ,@modules))
       ;; Set store and state directories inside `guix-gd-root`
       ((#:configure-flags flags '())
        ;; TODO: put this logic into `modify-flags` function
        ;; #~(modify-flags #$flags
        ;;                 '(("--with-store-dir" . #$(string-append guix-gd-root "/gnu/store"))
        ;;                   ("--localstatedir" . #$(string-append guix-gd-root "/var"))
        ;;                   ("--sysconfdir" . #$(string-append guix-gd-root "/etc"))
        ;;                   ("--with-channel-commit" . #$commit)))
        #~(cons* #$(string-append "--with-store-dir=" guix-gd-root "/gnu/store")
                 #$(string-append "--localstatedir=" guix-gd-root "/var")
                 #$(string-append "--sysconfdir=" guix-gd-root "/etc")
                 ;; to avoid 'guix pull' make guix know what commit it actually is
                 ;; this flag seems to be undocumented... it is used in:
                 ;; - guix/gnu/packages/package-management.scm
                 ;; - guix/etc/teams/release/artifacts-manifest.scm
                 #$(string-append "--with-channel-commit=" commit)
                 ;; remove default flags
                 (filter (lambda (flag)
                           (not (let loop ((prefixes '("--with-channel-commit="
                                                       "--sysconfdir="
                                                       "--localstatedir=")))
                                  (cond
                                   ((null? prefixes) #f)
                                   ((string-prefix? (car prefixes) flag) #t)
                                   (else (loop (cdr prefixes)))))))
                         #$flags)))
       ;; wrapper script for starting fallback guix daemon with new socket and build users
       ((#:phases phases)
        #~(modify-phases
           #$phases
           ;; if we use (add-after 'install 'wrap-commands) it will be applied before
           ;; original (add-after 'install 'wrap-program) which effects will silently do nothing
           ;; TODO: maybe add some warnings if (add-after 'install 'wrap-program) fails to upstream guix
           (add-after 'wrap-program 'wrap-commands
                      (lambda* (#:key outputs #:allow-other-keys)
                        (let* ((bin (string-append #$output "/bin"))
                               ;; bash-minimal is already input for guix
                               (sh #$(file-append (this-package-input "bash-minimal") "/bin/sh"))
                               (socket #$(string-append guix-gd-root "/var/guix/daemon-socket/socket"))
                               (store #$(string-append guix-gd-root "/gnu/store"))
                               (state #$(string-append guix-gd-root "/let"))
                               (daemon (string-append bin "/guix-daemon"))
                               (wrapper-as-root (string-append bin "/" #$name "-daemon-as-root"))
                               (wrapper-unprivileged (string-append bin "/" #$name "-daemon-unprivileged")))
                          ;; wrap guix-daemon command
                          (with-output-to-file wrapper-as-root
                            (lambda ()
                              (format #t
                                      "#!~a\nexec ~a --listen=~a --build-users-group=~a \"$@\"\n"
                                      sh daemon socket #$guix-gd-group)))
                          (chmod wrapper-as-root #o755)
                          ;; when running as unprivileged with `--build-users-group` flag
                          ;; it attempts to do root stuff
                          (with-output-to-file wrapper-unprivileged
                            (lambda ()
                              (format #t
                                      "#!~a\nexec ~a --listen=~a \"$@\"\n"
                                      sh daemon socket)))
                          (chmod wrapper-unprivileged #o755)
                          ;; wrap guix command
                          (wrap-program (string-append #$output "/bin/guix")
                                        `("GUIX_STATE_DIRECTORY" = (,state))
                                        `("GUIX_STORE_DIRECTORY" = (,store))
                                        `("NIX_STORE_DIR" = (,store))
                                        `("GUIX_DAEMON_SOCKET" = (,socket)))))))))))))

