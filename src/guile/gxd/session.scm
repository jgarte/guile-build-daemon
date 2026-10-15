;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd session)
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:export (unix-peer-trusted? initial-options))

(define-record-type <options>
  (make-options keep-failed? keep-going? verbosity offload?
                build-verbosity log-type print-build-trace? settings)
  options?
  (keep-failed? options-keep-failed?)
  (keep-going? options-keep-going?)
  (verbosity options-verbosity)
  (offload? options-offload?)
  (build-verbosity options-build-verbosity)
  (log-type options-log-type)
  (print-build-trace? options-print-build-trace?)
  (settings options-settings))

(define (initial-options offload?)
  "Return initial session options with OFFLOAD? indicating build-hook availability.
Retain named settings as unique string pairs; substitution starts enabled."
  (make-options #f #f 1 offload? 0 0 #f
                '(("build-use-substitutes" . "true"))))

(define (unix-peer-trusted? peer-uid daemon-uid)
  (or (zero? peer-uid) (= peer-uid daemon-uid)))
