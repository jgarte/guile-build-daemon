;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd file-store-test)
  #:use-module ((ares suitbl core)
                #:select (define-suite
                           is
                           test))
  #:use-module ((gcrypt hash) #:select (sha256))
  #:use-module ((guix serialization)
                #:select (write-file
                          write-file-tree))
  #:use-module ((guix store database) #:prefix guix-db: #:select (call-with-database))
  #:use-module ((gxd database) #:prefix database: #:select (valid-path?))
  #:use-module ((gxd file-store)
                #:select (add-nar-to-store
                          call-with-bytevector-input-port
                          call-with-bytevector-output-port))
  #:use-module ((gxd store-path) #:select (fixed-output-path))
  #:use-module ((guix utils) #:select (call-with-temporary-directory))
  #:use-module ((rnrs bytevectors) #:select (bytevector=?
                                             string->utf8))
  #:use-module ((rnrs io ports) #:select (get-u8
                                          put-bytevector
                                          put-u8))
  #:use-module (gxd test-prelude))

(define (nar-bytes source)
  "Return SOURCE's normalized NAR as a bytevector."
  (call-with-bytevector-output-port
   (lambda (port) (write-file source port))))

(define (nar-with-entry name)
  (call-with-bytevector-output-port
   (lambda (port)
     (write-file-tree "root" port
                      #:file-type+size (lambda (file) (values (if (string=? file "root") 'directory 'regular) 0))
                      #:file-port (lambda _ (open-input-string ""))
                      #:directory-entries (lambda _ (list name))
                      #:postprocess-entries identity))))

(define (call-with-tmp-dir-and-database proc)
  "Call PROC with a temporary directory and a database."
  (call-with-temporary-directory
   (lambda (tmp-dir)
     (define (proc-tmp-dir db) (proc tmp-dir db))
     (let ((database-file (string-append tmp-dir "/db.sqlite")))
       (guix-db:call-with-database database-file proc-tmp-dir)))))

(define-suite (file-store-tests)
  (test "recursive import restores and registers a regular file" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (call-with-hello-world-file
        (lambda (source)

          (define nar (nar-bytes source))
          (define hash (sha256 nar))
          (define expected (fixed-output-path dir "item" hash))
          (define destination (call-with-bytevector-input-port nar
                                (lambda (input)
                                  (add-nar-to-store db dir "item" #t "sha256" input))))
          
          (is (equal? expected destination))
          (is (database:valid-path? db destination))
          (is (file-exists? destination))
          ;; read-only r--r--r--
          (is (= #o444 (stat:perms (stat destination))))
          (is (equal? destination
                      (call-with-bytevector-input-port nar
                        (lambda (input)
                          (add-nar-to-store db dir "item" #t "sha256" input))))))))))

  (test "recursive import restores the received canonical NAR" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (call-with-hello-world-file
        (lambda (source)
          (define nar (nar-bytes source))
          (define destination
            (call-with-bytevector-input-port nar
              (lambda (input)
                (add-nar-to-store db dir "item" #t "sha256" input))))
          (is (bytevector=? nar (nar-bytes destination))))))))

  (test "recursive import rejects invalid NAR entry names" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (define (malformed-nar-raised? name)
         (capture-exception
          (lambda ()
            (call-with-bytevector-input-port (nar-with-entry name)
              (lambda (input)
                (add-nar-to-store db dir "item" #t "sha256" input))))))

       (is (malformed-nar-raised? ""))
       (is (malformed-nar-raised? "."))
       (is (malformed-nar-raised? ".."))
       (is (malformed-nar-raised? "a/b"))
       (is (malformed-nar-raised? (string #\nul)))
       (is (malformed-nar-raised? "../escaped"))
       (is (not (file-exists? (string-append dir "/escaped")))))))

  (test "recursive import canonicalizes tree metadata" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
     (define source (string-append dir "/source"))
     (define program (string-append source "/program"))
     (define link (string-append source "/link"))
     
     (mkdir source)
     (spit program "contents")
     (chmod program #o777)
     (symlink "program" link)
     
     (define destination
       (call-with-bytevector-input-port (nar-bytes source)
         (lambda (input)
           (add-nar-to-store db dir "item" #t "sha256" input))))

     (is (= 1 (stat:mtime (lstat destination))))
     (is (= 1 (stat:mtime (lstat (string-append destination "/program")))))
     (is (= 1 (stat:mtime (lstat (string-append destination "/link")))))
     
     (is (= #o555 (stat:perms (stat destination))))
     (is (= #o555 (stat:perms (stat (string-append destination "/program")))))
     (chmod destination #o755))))

  (test "recursive port import consumes exactly one NAR" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (call-with-hello-world-file
        (lambda (source)
          (define bytes
            (call-with-bytevector-output-port
             (lambda (output)
               ;; The byte after the NAR models the next protocol input.
               (put-bytevector output (nar-bytes source))
               (put-u8 output 42))))

          (call-with-bytevector-input-port bytes
            (lambda (input)
              (define destination (add-nar-to-store db dir "item" #t "sha256" input))
              
              (is (database:valid-path? db destination))
              (is (= 42 (get-u8 input))))))))))

  (test "recursive import rejects NARs deeper than nixd's limit" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (define source (string-append dir "/source"))
       (define deepest source)
       (mkdir source)

       (let loop ((parent source) (depth 0))
         (when (< depth 255)
           (let ((child (string-append parent "/dir")))
             (mkdir child)
             (set! deepest child)
             (loop child (1+ depth)))))

       (define (dir-nesting-too-deep? source)
         (capture-exception
          (lambda ()
            (call-with-bytevector-input-port (nar-bytes source)
              (lambda (input)
                (add-nar-to-store db dir "item" #t "sha256" input))))))
       
       (is (not (dir-nesting-too-deep? source)))

       (mkdir (string-append deepest "/dir"))
       
       (is (dir-nesting-too-deep? source)))))

  (test "flat port import stores regular-file contents" ()
    (call-with-tmp-dir-and-database
     (lambda (dir db)
       (call-with-hello-world-file
        (lambda (source)
          (define bytes
            (call-with-bytevector-output-port
             (lambda (output)
               (put-bytevector output (nar-bytes source)))))
          (call-with-bytevector-input-port bytes
            (lambda (input)
              (define destination (add-nar-to-store db dir "item" #f "sha256" input))
              (define expected (fixed-output-path
                                dir "item" (sha256 (string->utf8 "Hello World!"))
                                #:recursive? #f))
              
              (is (equal? expected destination))
              (is (database:valid-path? db destination))
              (is (= #o444 (stat:perms (stat destination)))))))
        #:content "Hello World!")))))

