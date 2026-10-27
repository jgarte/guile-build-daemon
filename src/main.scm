;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(use-modules ((gxd server) #:select (run-server))
             ((guix config) #:select (%state-directory))
             ((guix build utils) #:select (mkdir-p executable-file?))
             ((ice-9 getopt-long) #:select (getopt-long option-ref))
             ((srfi srfi-98) #:select (get-environment-variables)))

(define options
  (getopt-long (command-line) '((disable-chroot (value #f)))))

(let ((guix-program (getenv "GUIX")))
  (unless (and guix-program (absolute-file-name? guix-program)
               (executable-file? guix-program))
    (error "GUIX must name an absolute executable file" guix-program)))

(define socket-directory
  (string-append %state-directory "/daemon-socket"))

(mkdir-p socket-directory)
(run-server (string-append socket-directory "/socket")
            (getenv "GUIX") (get-environment-variables)
            (not (option-ref options 'disable-chroot #f)))
