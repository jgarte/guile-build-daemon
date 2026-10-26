;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(use-modules ((gxd server) #:select (run-server))
             ((guix config) #:select (%state-directory))
             ((guix build utils) #:select (mkdir-p))
             ((ice-9 getopt-long) #:select (getopt-long option-ref)))

(define options
  (getopt-long (command-line) '((disable-chroot (value #f)))))

(define socket-directory
  (string-append %state-directory "/daemon-socket"))

(mkdir-p socket-directory)
(run-server (string-append socket-directory "/socket")
            (not (option-ref options 'disable-chroot #f)))
