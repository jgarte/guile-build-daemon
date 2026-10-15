;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox files-info)
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module (srfi srfi-1 #:select (append-map)) 
  #:export (scan-files-info))

(define (file-info path stat)
  "Return info about file metadata at PATH from STAT."
  (append `((type . ,(stat:type stat))
            (mode . ,(logand #o7777 (stat:mode stat)))
            (uid . ,(stat:uid stat))
            (gid . ,(stat:gid stat)))
          (if (eq? 'regular (stat:type stat))
              `((size . ,(stat:size stat)))
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
