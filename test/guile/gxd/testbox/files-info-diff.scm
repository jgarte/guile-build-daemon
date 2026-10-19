;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox files-info-diff)
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((ice-9 match) #:select (match))
  #:use-module ((srfi srfi-1)
                #:select (append-map delete-duplicates))
  #:export (diff-files-info format-files-info-diff scan-files-info))

(define (file-info path stat)
  "Return PATH's type, mode and ownership from STAT, plus its symlink target."
  (append `((type . ,(stat:type stat))
            (mode . ,(logand #o7777 (stat:mode stat)))
            (uid . ,(stat:uid stat))
            (gid . ,(stat:gid stat)))
          (if (eq? 'symlink (stat:type stat))
              `((target . ,(readlink path)))
              '())))

(define (scan-files-info root)
  "Return ROOT's tree metadata as an alist sorted by relative path.
Include ROOT as \".\" and do not follow symlinks."
  (define (walk relative)
    (let* ((dot? (string=? relative "."))
           (path (if dot? root (string-append root "/" relative)))
           (stat (lstat path))
           (entry (cons relative (file-info path stat))))
      (if (eq? 'directory (stat:type stat))
          (cons entry
                (append-map (lambda (name)
                              (walk (if dot? name (string-append relative "/" name))))
                            (scandir path (lambda (f) (not (member f '("." "..")))))))
          (list entry))))

  (sort (walk ".") (lambda (a b) (string<? (car a) (car b)))))

(define (diff-files-info left right)
  "Compare inventories LEFT and RIGHT, sorted by unique path.
Return paths+info present only in LEFT, only in RIGHT, and changed in both."
  (define (diff-info left-info right-info)
    (filter (lambda (field)
              (not (equal? (assoc-ref left-info field)
                           (assoc-ref right-info field))))
            (delete-duplicates (append (map car left-info) (map car right-info)))))

  (define (result only-left only-right changed)
    `((only-left . ,only-left)
      (only-right . ,only-right)
      (changed . ,(reverse changed))))

  (let walk ((left left) (right right)
             (only-left '()) (only-right '()) (changed '()))
    (match (list left right)
      ((() _)
       (result (reverse only-left) (append (reverse only-right) right) changed))
      ((_ ())
       (result (append (reverse only-left) left) (reverse only-right) changed))
      ((((left-path . left-info) . left-rest)
        ((right-path . right-info) . right-rest))
       (cond
        ((string<? left-path right-path)
         (walk left-rest right (cons (cons left-path left-info) only-left) only-right changed))
        ((string<? right-path left-path)
         (walk left right-rest only-left (cons (cons right-path right-info) only-right) changed))
        (else
         (let ((fields (diff-info left-info right-info)))
           (walk left-rest right-rest only-left only-right
                 (if (null? fields)
                     changed
                     (cons (list left-path fields left-info right-info) changed))))))))))

(define (format-files-info-diff diff)
  "Format DIFF for an assertion failure."
  (define (format-paths port label marker entries)
    (unless (null? entries)
      (format port "~%~a:~%" label)
      (for-each (lambda (entry) (format port "  ~a /~a~%" marker (car entry)))
                entries)))

  (define (format-changes port changes)
    (for-each
     (lambda (change)
       (format port "~%changed: /~a~%" (car change))
       (for-each (lambda (field)
                   (format port "  ~a: ~s != ~s~%" field
                           (assoc-ref (caddr change) field)
                           (assoc-ref (cadddr change) field)))
                 (cadr change)))
     changes))

  (call-with-output-string
   (lambda (port)
     (format port "filesystem artifacts differ~%")
     (format-paths port "only in left" "+" (assoc-ref diff 'only-left))
     (format-paths port "only in right" "-" (assoc-ref diff 'only-right))
     (format-changes port (assoc-ref diff 'changed)))))
