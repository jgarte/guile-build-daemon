;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd session)
  #:use-module ((ice-9 exceptions) #:select (&error define-exception-type
                                                    raise-exception))
  #:use-module ((ice-9 format) #:select (format))
  #:use-module ((ice-9 match) #:select (match match-lambda))
  #:use-module ((ice-9 regex) #:select (string-match match:start match:end
                                                     match:substring))
  #:use-module (gxd prelude)
  #:use-module ((srfi srfi-1) #:select (alist-delete fold))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:use-module ((system foreign) #:select (sizeof unsigned-int unsigned-long))
  #:export (unix-peer-trusted? initial-options
                               &option-error option-error? option-error-message))

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

(define-exception-type &option-error &error
  make-option-error option-error?
  (message option-error-message))

;; Settings::update validates in this order; build-repeat is parsed later.
(define setting-types
  '(("build-fallback" . boolean)
    ("build-max-jobs" . unsigned-int)
    ("build-cores" . unsigned-int)
    ("system" . string)
    ("multiplexed-build-output" . boolean)
    ("build-max-silent-time" . time-t)
    ("build-timeout" . time-t)
    ("gc-reserved-space" . off-t)
    ("fsync-metadata" . boolean)
    ("use-sqlite-wal" . boolean)
    ("sync-before-registering" . boolean)
    ("build-use-substitutes" . boolean)
    ("build-users-group" . string)
    ("build-use-chroot" . boolean)
    ("build-impersonate-linux-26" . boolean)
    ("build-keep-log" . boolean)
    ("build-max-log-size" . unsigned-long)
    ("build-cache-failure" . boolean)
    ("build-poll-interval" . unsigned-int)
    ("gc-check-reachability" . boolean)
    ("gc-keep-outputs" . boolean)
    ("gc-keep-derivations" . boolean)
    ("auto-optimise-store" . boolean)
    ("env-keep-derivations" . boolean)))

(define (parse-option-boolean name value)
  "Return textual VALUE as a Boolean; raise an option error naming NAME if invalid."
  (match value
    ("true" #t)
    ("false" #f)
    (_
     (raise-exception
      (make-option-error
       (format #f "configuration option `~a' should be either `true' or `false', not `~a'"
               name value))))))

(define (options-use-substitutes? options)
  "Return whether OPTIONS permits substitution."
  (define key "build-use-substitutes")
  (parse-option-boolean key (assoc-ref (options-settings options) key)))

(define (parse-option-integer name value type)
  "Return VALUE as C++ integer TYPE; raise an option error naming NAME if invalid."
  (or (parse-integer-for-type value type)
      (raise-exception
       (make-option-error
        (format #f "configuration setting `~a' should have an integer value"
                name)))))

(define (validate-settings settings)
  "Validate SETTINGS in nixd update order without changing its textual values.
SETTINGS has unique string keys.  Defer unrecognized settings to their consumers.
Raise an option error for the first invalid recognized setting."
  (for-each
   (match-lambda
     ((name . type)
      (and-let* ((setting (assoc name settings))
                 (value (cdr setting)))
        (case type
          ((string) #t)
          ((boolean) (parse-option-boolean name value))
          (else (parse-option-integer name value type))))))
   setting-types))
