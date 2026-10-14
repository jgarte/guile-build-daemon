;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd session)
  #:export (unix-peer-trusted?))

(define (unix-peer-trusted? peer-uid daemon-uid)
  (or (zero? peer-uid) (= peer-uid daemon-uid)))
