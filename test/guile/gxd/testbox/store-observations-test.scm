;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox store-observations-test)
  #:use-module ((ares suitbl core) #:select (define-suite is test))
  #:use-module ((ares suitbl checks) #:select (throws-exception?))
  #:use-module ((guix store) #:select (direct-store-path))
  #:use-module ((gxd testbox) #:select (paired-daemon-testboxes-fixture testbox-root))
  #:use-module ((gxd testbox snapshots) #:select (paired-snapshots-fixture))
  #:use-module ((gxd testbox store-observations) #:select (store-observations-fixture))
  #:use-module (gxd test-prelude))

(define-suite (store-observations-tests)
  'metadata `((test/fixtures
               . ,(list (paired-daemon-testboxes-fixture 'rootless 'nixd 'nixd)
                        paired-snapshots-fixture
                        store-observations-fixture)))

  (test "equal store inventories include a seeded item" (ctx)
    (let ((present (basename (direct-store-path
                              (canonicalize-path (require-program "guix-daemon"))))))
      (is (assoc present ((get ctx 'observe-store!))))))

  (test "a left-only store entry is reported" (ctx)
    (let ((left (get ctx 'testbox/left))
          (observe-store! (get ctx 'observe-store!)))
      (spit (string-append (testbox-root left) "/gnu/store/gxd-diff-sentinel")
            "left only")
      (is (throws-exception? (observe-store!))))))
