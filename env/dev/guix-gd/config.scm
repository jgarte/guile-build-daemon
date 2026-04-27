(define-module (guix-gd config))
(define this-module (resolve-module '(guix-gd config)))

;; root directory for development and testing guile guix daemon
;; separates disk IO of dev daemon from current system daemon
;; follows standard structure and requires that these are present
;; - ./gnu/store/
;; - ./var/guix/daemon-socket/
;; - ./etc/
(define-public guix-gd-root "/guix-gd-root")

(define-public guix-gd-container-root "/guix-gd-container")

;; group for build users for dev guix guile daemon
;; also a prefix name for these build users names
(define-public guix-gd-group "guix-gd-build")

;; group name and user name for unprivileged daemon
(define-public guix-gd-user "guix-gd-daemon")

(define-public guix-gd-dev-sock "/tmp/guix-gd-fallback.sock")

;; configs for overlayfs daemon
(define-public guix-gd-dev-root "/guix-gd-overlayfs")
(define-public guix-gd-daemon-user "root")
(define-public guix-gd-daemon-group "root")
(define-public guix-gd-client-user "stas")



(define config-dev-vars
  '(guix-gd-root
    guix-gd-container-root
    guix-gd-group
    guix-gd-user
    guix-gd-dev-sock
    ;; configs for overlayfs daemon
    guix-gd-dev-root
    guix-gd-daemon-user
    guix-gd-daemon-group
    guix-gd-client-user))


;; utils
(define (symbol->env-name var)
  "Return symbol name upcased replacing '-' with '_'"
  (list->string
   (map (lambda (c) (if (char=? c #\-) #\_ (char-upcase c)))
        (string->list (symbol->string var)))))

(define (symbol->val var) (module-ref this-module var))

(define (string-join-space items)
  (if (null? items)
      ""
      (let loop ((rest (cdr items))
                 (acc (car items)))
        (if (null? rest)
            acc
            (loop (cdr rest)
                  (string-append acc " " (car rest)))))))


;; useless
(define-public (config-dev-setenv)
  "Set process environment variables.
NOTE: Those are seen only by the Guile process itself and by processes started from that Guile process. It can not set env for parent processes."
  (for-each
   (lambda (var)
     (setenv (symbol->env-name var)
             (symbol->val var)))
   config-dev-vars))

;; (environ)


(define-public (config-dev-env)
  "Return shell assignment chain: VAR=VAL VAR2=VAL2 ..."
  (string-join-space
   (map (lambda (var)
          (string-append (symbol->env-name var)
                         "="
                         (symbol->val var)))
        config-dev-vars)))

;; (config-dev-env)
