;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(use-modules ((guix profiles) #:select (packages->manifest))
             ((gxd env guix packages) #:select (guix-package)))

(packages->manifest (list guix-package))
