;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd accounts)
  #:use-module ((system foreign) #:select (unsigned-int pointer->procedure
                                           null-pointer?))
  #:export (user-exists?))

(define lookup-user
  (pointer->procedure '* (dynamic-func "getpwuid" (dynamic-link))
                      (list unsigned-int)))

(define (user-exists? uid)
  "Return whether UID has a passwd entry, using libc's account lookup."
  (not (null-pointer? (lookup-user uid))))
