;;; Daemon-side control-frame parser.
;;;
;;; For each client operation, daemon output is layered as:
;;;
;;;   [zero or more STDERR_* control frames]
;;;   STDERR_LAST
;;;   [operation-specific reply payload]
;;;
;;; This module decodes only the control-frame layer.  Reply payloads are
;;; decoded separately in (gxd protocol reply).

(define-module (gxd protocol daemon)
  #:use-module (gxd protocol constants)
  #:use-module (gxd protocol primitives)
  #:export (parse-daemon-frame-at))

(define (parse-daemon-frame-at bv start client-minor)
  "Parse one daemon control frame from BV at START.

Event shapes:
  (next MESSAGE NEXT)
  (read MAX-LEN NEXT)
  (write LEN NEXT)
  (error MESSAGE STATUS-OR-#f NEXT)
  (last #f NEXT)
  (unknown CODE NEXT)

Only the control-frame layer is decoded here.  The ordinary operation reply
payload that follows `STDERR_LAST` remains for the reply parser."
  (let ((code-result (parse-int-at bv start)))
    (and code-result
         (let ((code (parsed-value code-result))
               (index (parsed-next code-result)))
           (cond
            ((= code STDERR_NEXT)
             (let ((msg-result (parse-string-at bv index)))
               (and msg-result
                    (list 'next
                          (parsed-value msg-result)
                          (parsed-next msg-result)))))
            ((= code STDERR_READ)
             (let ((len-result (parse-int-at bv index)))
               (and len-result
                    (list 'read
                          (parsed-value len-result)
                          (parsed-next len-result)))))
            ((= code STDERR_WRITE)
             (let ((len-result (parse-int-at bv index)))
               (and len-result
                    (let* ((len (parsed-value len-result))
                           (payload-start (parsed-next len-result))
                           (need (+ len (padding-size len))))
                      ;; STDERR_WRITE carries raw payload bytes after length.
                      ;; We do not decode bytes, only skip them safely.
                      (and (bytes-available? bv payload-start need)
                           (list 'write len (+ payload-start need)))))))
            ((= code STDERR_ERROR)
             (let ((msg-result (parse-string-at bv index)))
               (and msg-result
                    ;; Newer protocol minors append an integer status code.
                    (if (and client-minor (>= client-minor 8))
                        (let ((status-result
                               (parse-int-at bv (parsed-next msg-result))))
                          (and status-result
                               (list 'error
                                     (parsed-value msg-result)
                                     (parsed-value status-result)
                                     (parsed-next status-result))))
                        (list 'error
                              (parsed-value msg-result)
                              #f
                              (parsed-next msg-result))))))
            ((= code STDERR_LAST)
             (list 'last #f index))
            (else
             (list 'unknown code index)))))))
