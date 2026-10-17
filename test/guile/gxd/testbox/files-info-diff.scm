;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox files-info-diff)
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((gcrypt base16) #:select (bytevector->base16-string))
  #:use-module ((gcrypt hash) #:select (file-sha256))
  #:use-module ((srfi srfi-1)
                #:select (append-map delete-duplicates filter-map))
  #:export (diff-files-info format-files-info-diff scan-files-info))

(define (file-info path stat)
  "Return info about file metadata at PATH from STAT."
  (append `((type . ,(stat:type stat))
            (mode . ,(logand #o7777 (stat:mode stat)))
            (uid . ,(stat:uid stat))
            (gid . ,(stat:gid stat)))
          (if (eq? 'regular (stat:type stat))
              `((size . ,(stat:size stat))
                (digest . ,(bytevector->base16-string (file-sha256 path))))
              '())
          (if (eq? 'symlink (stat:type stat))
              `((target . ,(readlink path)))
              '())))

(define (scan-files-info root)
  "Return ROOT's files paths and info (metadata, etc) as a path-sorted alist.
Symlinks are not followed. Paths would be relative to ROOT."
  ;; Can not use 'ftw' here as it step into symlinked dirs
  (define (walk relative)
    (let* ((dot?  (string=? relative "."))
           (path  (if dot? root (string-append root "/" relative)))
           (stat  (lstat path))
           (entry (cons relative (file-info path stat))))
      (if (eq? 'directory (stat:type stat))
          (cons entry 
                (append-map (lambda (name)
                              (walk (if dot? name (string-append relative "/" name))))
                            (scandir path (lambda (f) (not (member f '("." "..")))))))
          (list entry))))
  
  (sort (walk ".") (lambda (a b) (string<? (car a) (car b)))))


(define (diff-files-info left right)
  "Return paths+info present only in LEFT, only in RIGHT, and changed in both."
  (define (diff-info left-info right-info)
    (filter (lambda (field)
              (not (equal? (assoc-ref left-info field)
                           (assoc-ref right-info field))))
            (delete-duplicates (append (map car left-info) (map car right-info)))))
  (let ((only-left (filter
                    (lambda (entry) (not (assoc (car entry) right)))
                    left))
        (only-right (filter
                     (lambda (entry) (not (assoc (car entry) left)))
                     right))
        (changed (filter-map
                  (lambda (left-file-info)
                    (let ((right-file-info (assoc (car left-file-info) right)))
                      (and right-file-info
                          (let ((fields (diff-info
                                         (cdr left-file-info)
                                         (cdr right-file-info))))
                            (and (pair? fields)
                                 (list (car left-file-info)
                                       fields
                                       (cdr left-file-info)
                                       (cdr right-file-info)))))))
                  left)))
    `((only-left . ,only-left)
      (only-right . ,only-right)
      (changed . ,changed))))

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
