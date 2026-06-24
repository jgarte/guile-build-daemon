;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin

(use-modules (ares server)
             (fibers))

;; Run Ares with fibers preemption disabled (hz=0) on this machine.
;;
;; We start the nREPL server in the current scheduler
;; (standalone? #f) and keep an anchor fiber alive.
(run-fibers
 (lambda ()
   ((@ (ares server) run-nrepl-server)
    #:standalone? #f)
   (let loop ()
     (sleep 3600)
     (loop)))
 #:hz 0
 #:drain? #t)
