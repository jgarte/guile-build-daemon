;; SPDX-License-Identifier: GPL-3.0-or-later
;; SPDX-FileCopyrightText: 2026 Andrew Tropin
;; SPDX-FileCopyrightText: 2026 Andrew Zhurov
;; SPDX-FileCopyrightText: 2026 buttonspresser

(define-module (gxd testbox-relay observer)
  #:use-module ((rnrs bytevectors)
                #:select (bytevector-copy!
                          bytevector-u64-ref
                          endianness
                          make-bytevector))
  #:use-module ((srfi srfi-1) #:select (find))
  #:use-module ((srfi srfi-9) #:select (define-record-type))
  #:use-module ((guix build syscalls) #:select (restart-on-EINTR))
  #:use-module ((gxd testbox-relay observation-protocol)
                #:select (frame-accepted
                          frame-data
                          frame-terminated)
                #:prefix observation:)
  #:export (close-relay-input!
            make-observed-connection
            make-relay-observer
            read-next-completed-connection!
            observed-connection-id
            observed-connection-observations
            observed-connection-status
            relay-observer-observed-connections))

;;; One observation stream describes many retained connections:
;;;
;;;   (make-relay-observer INPUT)
;;;     -> OBSERVER owns INPUT and an empty connection list
;;;
;;;   (read-next-completed-connection! OBSERVER DEADLINE)
;;;     -> read and apply INPUT frames until the next TERMINATED
;;;
;;; Within one call every read uses that absolute DEADLINE.  A later call
;;; continues from INPUT's current position.  Applying a frame changes its
;;; connection as follows:
;;;
;;;   ACCEPTED ID
;;;     absent
;;;       -> (ID open ())
;;;
;;;   DATA ID FROM BYTES
;;;     (ID open (OBSERVATIONS ...))
;;;       -> (ID open (OBSERVATIONS ... (FROM . BYTES)))
;;;
;;;   TERMINATED ID complete
;;;     (ID open OBSERVATIONS)
;;;       -> (ID complete OBSERVATIONS); return the connection
;;;
;;; Connections stay in acceptance order.  Their observations stay in arrival
;;; order, even when frames from several connections are interleaved.

(define-record-type <observed-connection>
  (make-observed-connection connection-id status observations)
  observed-connection?
  (connection-id observed-connection-id)
  (status observed-connection-status set-observed-connection-status!)
  (observations observed-connection-observations
                set-observed-connection-observations!))

(define-record-type <relay-observer>
  (%make-relay-observer relay-input observed-connections)
  relay-observer?
  (relay-input relay-observer-relay-input)
  (observed-connections relay-observer-observed-connections
                        set-relay-observer-observed-connections!))

(define (make-relay-observer relay-input)
  "Return an observer over RELAY-INPUT with no retained connections."
  (%make-relay-observer relay-input '()))

(define (connection-by-id observer connection-id)
  (find (lambda (connection)
          (= connection-id (observed-connection-id connection)))
        (relay-observer-observed-connections observer)))

(define (require-open-connection observer connection-id)
  "Return CONNECTION-ID from OBSERVER if it is open; otherwise raise."
  (let ((connection (connection-by-id observer connection-id)))
    (unless connection
      (error "unknown observed connection" connection-id))
    (unless (eq? 'open (observed-connection-status connection))
      (error "observed connection is already terminal" connection-id))
    connection))

(define (read-exactly observer length deadline)
  "Return LENGTH bytes from OBSERVER by absolute DEADLINE; raise on EOF or
timeout."
  (let loop ((bytes (make-bytevector length)) (position 0))
    (if (= position length)
        bytes
        (let ((timeout (- deadline (current-time))))
          (when (negative? timeout)
            (error "timed out reading relay observation"))
          (unless (memq (relay-observer-relay-input observer)
                        (car (select (list (relay-observer-relay-input observer))
                                     '() '() timeout)))
            (error "timed out reading relay observation"))
          (let* ((buffer (make-bytevector (- length position)))
                 (count (restart-on-EINTR
                         (recv! (relay-observer-relay-input observer) buffer))))
            (when (zero? count)
              (error "relay observation ended"))
            (bytevector-copy! buffer 0 bytes position count)
            (loop bytes (+ position count)))))))

(define (read-scalar observer deadline)
  (bytevector-u64-ref (read-exactly observer 8 deadline)
                      0 (endianness little)))

(define (read-data observer deadline)
  "Return one DATA payload from OBSERVER by DEADLINE."
  (let ((length (read-scalar observer deadline)))
    (read-exactly observer length deadline)))

(define (accept-connection! observer connection-id)
  "Register previously unseen CONNECTION-ID as open in OBSERVER."
  (unless (positive? connection-id)
    (error "invalid observed connection ID" connection-id))
  (when (connection-by-id observer connection-id)
    (error "duplicate observed connection" connection-id))
  (set-relay-observer-observed-connections!
   observer
   (append (relay-observer-observed-connections observer)
           (list (make-observed-connection connection-id 'open '()))))
  #f)

(define (record-data! observer connection-id from bytes)
  "Record BYTES under FROM for open CONNECTION-ID in OBSERVER."
  (let ((connection (require-open-connection observer connection-id))
        (from
         (case from
           ((1) 'client)
           ((2) 'daemon)
           (else (error "invalid relay observation source" from)))))
    (set-observed-connection-observations!
     connection
     (append (observed-connection-observations connection)
             (list (cons from bytes))))
    #f))

(define (finish-connection! observer connection-id status)
  "Return CONNECTION-ID's completed connection for a successful STATUS."
  (unless (= status 1) (error "invalid relay termination status" status))
  (let ((connection (require-open-connection observer connection-id)))
    (set-observed-connection-status! connection 'complete)
    connection))

(define (read-frame! observer deadline)
  "Apply OBSERVER's next frame by DEADLINE.  Return a completed connection,
#f for an accepted or data frame, or raise on failure."
  (let ((frame (read-scalar observer deadline)))
    (cond
     ((= frame observation:frame-accepted)
      (accept-connection! observer (read-scalar observer deadline)))
     ((= frame observation:frame-data)
      (let ((connection-id (read-scalar observer deadline))
            (from (read-scalar observer deadline)))
        (record-data! observer connection-id from
                      (read-data observer deadline))))
     ((= frame observation:frame-terminated)
      (let ((connection-id (read-scalar observer deadline))
            (status (read-scalar observer deadline)))
        (finish-connection! observer connection-id status)))
     (else (error "invalid relay observation frame" frame)))))

(define (read-next-completed-connection! observer deadline)
  "Return OBSERVER's next completed connection by absolute DEADLINE.  Raise if
observation fails or no connection completes by DEADLINE."
  (let loop ()
    (or (read-frame! observer deadline) (loop))))

(define (close-relay-input! observer)
  (close-port (relay-observer-relay-input observer)))
