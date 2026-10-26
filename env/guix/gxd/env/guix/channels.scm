;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(define-module (gxd env guix channels)
  #:use-module (guix channels)
  #:export (core-channels))

(define core-channels
  (list (channel
          (name 'guix)
          (url "https://codeberg.org/guix/guix.git")
          (branch "master")
          (commit
           "b3a2b7cbe5113e36880a20738a4b148969e93005")
          (introduction
           (make-channel-introduction
            "9edb3f66fd807b096b48283debdcddccfea34bad"
            (openpgp-fingerprint
             "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))))

core-channels
