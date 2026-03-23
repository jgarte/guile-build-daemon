(use-modules (guix packages)
             (guix download)
             (guix build-system copy)
             (gnu packages guile))

(package
 (name "guix-proxy")
 (version "0.1")
 (source (local-file "guix-gbd-proxy-cmd.scm"))
 (build-system copy-build-system)
 (arguments
  `(#:install-plan '(("guix-gbd-proxy-cmd.scm" "bin/guix-daemon-proxy"))
    #:phases
    (modify-phases
     %standard-phases
     (add-after 'install 'wrap-script
                (lambda* (#:key inputs outputs #:allow-other-keys)
                  (let* ((out (assoc-ref outputs "out"))
                         (bin (string-append out "/bin/guix-proxy"))
                         (guile (assoc-ref inputs "guile")))
                    (chmod bin #o755)
                    (wrap-program bin
                                  `("GUILE_LOAD_PATH" ":" prefix (,(string-append out "/share/guile/site/3.0")))
                                  `("PATH" ":" prefix (,(string-append guile "/bin"))))
                    #t))))))
 ;; TODO add guile shebang
 (inputs (list guile-3.0))
 (description "")
 (license #f))
