(define-module (dev guix-gd config))

;; root directory for development and testing guile guix daemon
;; separates disk IO of dev daemon from current system daemon
;; follows standard structure and requires that these are present
;; - ./gnu/store/
;; - ./var/guix/daemon-socket/
;; - ./etc/
(define-public guix-gd-root "/guix-gd-root")

;; group for build users for dev guix guile daemon
;; also a prefix name for these build users names
(define-public guix-gd-group "guix-gd-build")
