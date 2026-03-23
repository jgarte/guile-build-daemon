(use-modules (gnu packages package-management)
             (guix gexp)
             (guix packages)
             (guix utils)
             (gnu packages bash))

(define %guix-gbd-root "/tmp/guix-gbd-root")
(define %guix-gbd-group "guix-gbd")

(package
 (inherit guix-daemon)
 (name "guix-gbd-fallback")
 (inputs
  (modify-inputs (package-inputs guix-daemon)
                 (prepend bash-minimal guix)))
 (arguments
  (substitute-keyword-arguments
   (package-arguments guix-daemon)
   ;; Skip tests to save time.
   ((#:tests? tests? #f) #f)
   ;; Set store and state directories to be inside %guix-gbd-root.
   ((#:configure-flags flags '())
    #~(cons* #$(string-append "--with-store-dir=" %guix-gbd-root "/gnu/store")
             #$(string-append "--localstatedir=" %guix-gbd-root "/var")
             ;; not to mess with system settings
             #$(string-append "--sysconfdir=" %guix-gbd-root "/etc")
             ;; remove default flags
             (delete  "--sysconfdir=/etc" (delete "--localstatedir=/var" #$flags))))
   ;; binary and add --listen
   ((#:phases phases)
    #~(modify-phases
       #$phases
       (add-after 'install 'wrap-guix-daemon
                  (lambda* (#:key outputs #:allow-other-keys)
                    (let* ((bin (string-append #$output "/bin"))
                           (sh #$(file-append (this-package-input "bash-minimal") "/bin/sh"))
                           (guix-bin #$(file-append (this-package-input "guix") "/bin/guix"))
                           (socket #$(string-append %guix-gbd-root "/var/guix/daemon-socket/socket"))
                           (daemon (string-append bin "/guix-daemon"))
                           (wrapper (string-append bin "/guix-gbd-fallback")))
                      (with-output-to-file wrapper
                        (lambda ()
                          (format #t "#!~a
export GUIX=\"~a\"
exec ~a --listen=~a --build-users-group=~a \"$@\"
" sh guix-bin daemon socket #$%guix-gbd-group)))
                      (chmod wrapper #o755)))))))))








