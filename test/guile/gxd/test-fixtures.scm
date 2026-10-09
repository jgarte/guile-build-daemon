;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd test-fixtures)
  #:use-module ((gxd checked-steps) #:select (checked-steps-fixture))
  #:use-module ((gxd direct-steps) #:select (direct-steps-fixture))
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture))
  #:use-module ((gxd testbox-relay)
                #:select (client-trust-fixture paired-relay-observers-fixture))
  #:export (paired-testbox-fixtures))

(define* (paired-testbox-fixtures daemon-mode left-kind right-kind
                                  #:key (trusted-client? #f))
  "Return fixtures for checked direct steps on paired DAEMON-MODE subjects.
LEFT-KIND and RIGHT-KIND select daemons; TRUSTED-CLIENT? selects client trust.
E.g., (paired-testbox-fixtures 'rootless 'nixd 'nixd #:trusted-client? #t)."
  (list (client-trust-fixture trusted-client?)
        (paired-daemon-testboxes-fixture daemon-mode left-kind right-kind)
        paired-relay-observers-fixture
        direct-steps-fixture
        checked-steps-fixture))
