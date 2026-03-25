(define-module (guix-gd build-utils)
  #:use-module (srfi srfi-1)                      ; provides `find`, etc.
  )

(define-public (modify-flags flags new-flag-vals)
  "NEW-FLAG-VALS is alist of cons with flag name string as car and optional new value string as cdr. FLAGS is list to modify and return."
  (append
   (map
    (lambda (flag-value)
      (let ((flag (car flag-value))
            (val (cdr flag-value)))
        (if val
            ;; escape double quotes in values
            (let ((val (string-join (string-split val #\") "\\\"")))
              (string-append flag "=\"" val "\""))
            flag)))
    new-flag-vals)
   ;; remove default flags
   (filter (lambda (flag)
             (not (any (lambda (p)
                         (or (string=? p flag)
                             (string-prefix? (string-append p "=") flag)))
                       (map car new-flag-vals))))
           flags)))

;; test
;; (modify-flags '("--olala"
;;                 "--something=else"
;;                 "--store=/gnu/store"
;;                 "--sysconfdir=/etc"
;;                 "--localstatedir=/var")
;;               '(("--sysconfdir" . "/new-root/etc")
;;                 ("--localstatedir" . "/new-root/var")
;;                 ("--olala" . "bladiblada")))
