;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(use-modules ((gxd server) #:select (run-server))
             ((guix config) #:select (%state-directory))
             ((guix build utils) #:select (mkdir-p)))

(define socket-directory
  (string-append %state-directory "/daemon-socket"))

(mkdir-p socket-directory)
(run-server (string-append socket-directory "/socket"))
