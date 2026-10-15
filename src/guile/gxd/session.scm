;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd session)
  #:use-module ((ice-9 regex) #:select (string-match match:start match:end
                                                     match:substring))
  #:use-module ((srfi srfi-1) #:select (alist-delete fold))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:use-module ((system foreign) #:select (sizeof unsigned-int unsigned-long))
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

(define public-setting-keys
  '("build-timeout"
    "build-max-silent-time"
    "build-max-jobs"
    "build-cores"
    "build-repeat"
    "multiplexed-build-output"))

(define decimal-integer-pattern "[ \t\n\r\v\f]*([+-]?[0-9]+)")

(define (whole-string-match? matched value)
  (and (zero? (match:start matched))
       (= (match:end matched) (string-length value))))

(define (parse-decimal-integer value)
  "Parse decimal VALUE, allowing leading ASCII whitespace but no trailing text."
  (let ((matched (string-match decimal-integer-pattern value)))
    (and matched
         (whole-string-match? matched value)
         (string->number (match:substring matched 1) 10))))

(define (signed-integer-in-range number width)
  (let* ((maximum (1- (expt 2 (1- width))))
         (minimum (- (1+ maximum))))
    (and (<= minimum number maximum) number)))

(define (unsigned-integer-in-range number width)
  (let* ((modulus (expt 2 width))
         (maximum (1- modulus)))
    ;; C++ accepts a negative sign only when the magnitude fits.
    (and (<= (abs number) maximum)
         (modulo number modulus))))

(define (parse-integer-for-type value type)
  "Return decimal VALUE converted to C++ TYPE, or #f if invalid.
TYPE is unsigned-int, unsigned-long, time-t, or off-t.  Accept leading ASCII
whitespace but no trailing text; unsigned negative values wrap if their magnitude fits."
  (define number (parse-decimal-integer value))
  (and number
       (case type
         ((unsigned-int)
          (unsigned-integer-in-range number (* 8 (sizeof unsigned-int))))
         ((unsigned-long)
          (unsigned-integer-in-range number (* 8 (sizeof unsigned-long))))
         ;; time_t and off_t are signed 64-bit on the supported Linux x86-64 ABI.
         ((time-t off-t) (signed-integer-in-range number 64))
         (else (error "unsupported option integer type" type)))))

(define (merge-client-settings settings pairs trusted?)
  "Return SETTINGS updated by ordered client PAIRS; later values replace earlier ones.
Prefix non-public names with untrusted- unless TRUSTED?.  Preserve other settings."
  (fold (lambda (pair settings)
          (let* ((name (car pair))
                 (key (if (or trusted? (member name public-setting-keys))
                          name
                          (string-append "untrusted-" name))))
            (acons key (cdr pair) (alist-delete key settings string=?))))
        settings pairs))
