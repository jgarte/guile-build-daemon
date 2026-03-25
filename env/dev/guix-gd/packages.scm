(define-module (guix-gd packages)
  #:use-module (guix-gd config)                   ; provides `guix-gd-root` and `guix-gd-group`
  #:use-module (guix-gd channels)                 ; provides `guix-gd-channels`
  #:use-module (guix packages)                    ; provides `package`
  #:use-module (gnu packages package-management)  ; provides `guix` & `guix-daemon`
  #:use-module (gnu packages bash)                ; provides `bash-minimal`
  #:use-module (guix utils)                       ; provides `substitute-keyword-arguments`
  #:use-module (guix channels)                    ; provides `guix-channel?`
  #:use-module (guix build utils)                 ; provides `modify-phases`
  #:use-module (srfi srfi-1)                      ; provides `find`, etc.
  #:use-module (guix build-system channel)        ; provides `channel-build-system`
  #:use-module (guix git-download)                ; provides `git-fetch`, `git-reference`
  #:use-module (guix gexp))

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
       ;; Set store and state directories inside `guix-gd-root`
       ((#:configure-flags flags '())
        ;; TODO: put this logic into `modify-flags` function
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
           (add-after 'install 'wrap-commands
                      (lambda* (#:key outputs #:allow-other-keys)
                        (let* ((bin (string-append #$output "/bin"))
                               ;; bash-minimal is already input for guix
                               (sh #$(file-append (this-package-input "bash-minimal") "/bin/sh"))
                               (socket #$(string-append guix-gd-root "/var/guix/daemon-socket/socket"))
                               (store #$(string-append guix-gd-root "/gnu/store"))
                               (state #$(string-append guix-gd-root "/let"))
                               (daemon (string-append bin "/guix-daemon"))
                               (wrapper (string-append bin "/" #$name "-daemon")))
                          ;; wrap guix-daemon command
                          (with-output-to-file wrapper
                            (lambda ()
                              (format #t
                                      "#!~a\nexec ~a --listen=~a --build-users-group=~a \"$@\"\n"
                                      sh daemon socket #$guix-gd-group)))
                          (chmod wrapper #o755)
                          ;; wrap guix command
                          (wrap-program (string-append #$output "bin/guix")
                                        `("GUIX_STATE_DIRECTORY" = (,state))
                                        `("GUIX_STORE_DIRECTORY" = (,store))
                                        `("NIX_STORE_DIR" = (,store))
                                        `("GUIX_DAEMON_SOCKET" = (,socket)))))))))))))

