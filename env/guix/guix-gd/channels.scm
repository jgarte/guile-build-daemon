;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
(define-module (guix-gd channels)
  #:use-module (guix channels))

(define-public guix-gd-channels
  (list (channel
         (name 'guix)
         (url "https://git.guix.gnu.org/guix.git")
         (branch "master")
         (commit
          "c8985dd911c4c8e2948c888df8b54c9bc317625e")
         (introduction
          (make-channel-introduction
           "9edb3f66fd807b096b48283debdcddccfea34bad"
           (openpgp-fingerprint
            "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))))

;; return channels
guix-gd-channels
