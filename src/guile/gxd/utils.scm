(define-module (gxd utils)
  #:export (comment))

;; simple comment macro — bodies are read but not evaluated
(define-syntax comment
  (syntax-rules ()
    ((_ body ...)
     (begin))))   ; expands to an empty begin → unspecified value

(comment
 "doesn't eval on module eval")
