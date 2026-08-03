(define-module (gxd manifest)
  #:use-module (gnu packages)
  #:use-module (gnu packages package-management)
  #:use-module (guix profiles))

(packages->manifest
 ;; `current-guix' package metadata gets inherited from `guix' package;
 ;; but the source is as of the guix which executes this manifest
 (cons (current-guix)
       (map specification->package
            '("guile" "guile-ares-rs"))))
