;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd store-files-test)
  #:use-module (gxd test-prelude)
  #:use-module ((gxd store-files)
                #:select (canonicalize-metadata! unsupported-file-type-error-path
                                                 unsupported-file-type-error-type))
  #:use-module ((ares suitbl core) #:select (define-suite test is))
  #:use-module ((guix utils) #:select (call-with-temporary-directory)))

(define (call-with-output-directory proc)
  "Call PROC with a temporary directory; make it writable again before cleanup."
  (call-with-temporary-directory
   (lambda (directory)
     (call-with-cleanup
      (lambda () (chmod directory #o700))
      (lambda () (proc directory))))))

(define-suite (store-files-tests)
  (test "make files read-only, retaining owner-execute as execution permission for everyone" ()
    (call-with-output-directory
     (lambda (directory)
       (let ((initial-atime 123)
             (initial-mtime 456)
             (plain (string-append directory "/plain"))
             (executable (string-append directory "/executable")))
         (spit plain "plain")
         (spit executable "executable")
         (chmod plain #o600)
         (chmod executable #o700)
         (utime plain initial-atime initial-mtime)
         (utime executable initial-atime initial-mtime)
         (canonicalize-metadata! directory)

         (is (= #o555 (stat:perms (lstat directory))))
         (is (= #o444 (stat:perms (lstat plain))))
         (is (= #o555 (stat:perms (lstat executable))))
         (is (= 1 (stat:mtime (lstat plain)) (stat:mtime (lstat executable))))
         (is (= initial-atime (stat:atime (lstat plain)) (stat:atime (lstat executable))))))))

  (test "set a symlink's timestamp without changing its target" ()
    (call-with-temporary-directory
     (lambda (directory)
       (let ((target (string-append directory "/target"))
             (link (string-append directory "/link")))
         (spit target "target")
         (chmod target #o600)
         (utime target 123 456)
         (symlink target link)
         (define original-target-stats (lstat target))
         (canonicalize-metadata! link)

         (is (= 1 (stat:mtime (lstat link))))
         (is (= (stat:perms original-target-stats) (stat:perms (lstat target))))
         (is (= (stat:mtime original-target-stats) (stat:mtime (lstat target))))))))

  (test "normalize a file shared by two hard-linked names" ()
    (call-with-output-directory
     (lambda (directory)
       (let ((contents "shared")
             (first (string-append directory "/first"))
             (second (string-append directory "/second")))
         (spit first contents)
         (chmod first #o600)
         (link first second)
         (canonicalize-metadata! directory)

         (is (= (stat:ino (lstat first)) (stat:ino (lstat second))))
         (is (= #o444 (stat:perms (lstat first)) (stat:perms (lstat second))))
         (is (equal? contents (slurp second)))))))

  (test "reject a named pipe without changing its metadata" ()
    (call-with-temporary-directory
     (lambda (directory)
       (define pipe (string-append directory "/pipe"))
       (unless (zero? (system* (require-program "mkfifo") pipe))
         (error "could not create named pipe" pipe))
       (chmod pipe #o600)
       (utime pipe 123 456)
       (define original-pipe-stats (lstat pipe))

       (define actual-exception
         (capture-exception (lambda () (canonicalize-metadata! pipe))))

       (is (equal? pipe (unsupported-file-type-error-path actual-exception)))
       (is (eq? 'fifo (unsupported-file-type-error-type actual-exception)))
       (is (= (stat:perms original-pipe-stats) (stat:perms (lstat pipe))))
       (is (= (stat:mtime original-pipe-stats) (stat:mtime (lstat pipe))))))))
