;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov

(define-module (gxd isolation-test)
  #:use-module ((ice-9 match) #:select (match-let))
  #:use-module (ice-9 exceptions)
  #:use-module ((ice-9 atomic) #:select (make-atomic-box atomic-box-ref atomic-box-set!))
  #:use-module (ice-9 rdelim)

  #:use-module (ares suitbl core)
  #:use-module (ares suitbl checks)
  #:use-module ((gxd isolation) #:select (child-proc))
  #:use-module ((gxd prelude)))

(define (slurp file)
  (seek file 0 SEEK_SET)
  (read-string file))

(define-suite (child-proc-tests)
  (test "message receival blocks process until message arrival" ()
    (let ((file (tmpfile))
          (content "content"))
      (match-let (((_ => <=) (child-proc SIGCHLD
                              (lambda (=> <=)
                                (<= 'go)
                                (display content file)
                                (=> 'done)))))
        (is (string=? "" (slurp file)))
        (=> 'go)
        (<= 'done)
        (is (string=? content (slurp file))))))

  (test "when expecting message with one ID and get with another - throws" ()
        (match-let (((_ _ <=) (child-proc SIGCHLD
                                (lambda (=> _) (=> 1)))))
      (is (throws-exception? (<= 'not-1)))))

  (test "atomic-boxes are also isolated; child's mutation of the val isn't seen by parent" ()
    (let ((box (make-atomic-box 0)))
      (match-let (((_ _ <=) (child-proc SIGCHLD
                              (lambda (=> _)
                                (atomic-box-set! box 1)
                                (=> 'done)))))
        (<= 'done)
        (is (eq? (atomic-box-ref box) 0)))))

  (test "shared resources are CoW; child can't mutate parent's and vice-versa" ()
    (define *box #f) ;; shared res
    (match-let (((_ => <=) (child-proc SIGCHLD
                            (lambda (=> <=)
                              (=> 'child-alive)
                              (<= 'mutate!)
                              (set! *box #t)
                              (=> 'mutated *box)
                              (<= 'parent-mutated)
                              (=> 'child-value *box)))))
      (<= 'child-alive) ;; blocks on 'child-alive
      (=> 'mutate!)
      (is (eq? (<= 'mutated) #t)) ;; child mutated its own version of *box (CoW)
      (is (eq? *box #f)) ;; parent's version is intact
      (set! *box 1)
      (=> 'parent-mutated)
      (is (eq? (<= 'child-value) #t)))))
