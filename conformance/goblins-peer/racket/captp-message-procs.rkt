#lang racket/base
;; CapTP message framing over Racket ports.
;;
;; Goblins's CapTP reader loop expects `read-message` to return eof when the
;; transport closes. The Goblins 0.15 `read-write-procs` helper instead passes
;; that eof result to `syrup-decode`, which raises a contract error during an
;; ordinary session close. Keep the netlayer boundary honest here: EOF is a
;; stream result, while only framed bytes reach the Syrup decoder.

(require syrup)

(provide captp-message-procs)

(define default-max-frame-bytes (* 1024 1024))

(define (captp-message-procs in out
                             #:max-frame-bytes [max-frame-bytes default-max-frame-bytes])
  (unless (exact-nonnegative-integer? max-frame-bytes)
    (raise-argument-error 'captp-message-procs
                          "exact-nonnegative-integer?"
                          max-frame-bytes))
  (define max-length-digits
    (string-length (number->string max-frame-bytes)))
  (define (read-frame)
    (define first (read-byte in))
    (if (eof-object? first)
        eof
        (let loop ([byte first] [length 0] [digit-count 0])
          (cond
            [(eof-object? byte)
             (error 'read-message "stream ended within a CapTP frame")]
            [(and (<= 48 byte) (<= byte 57))
             (when (>= digit-count max-length-digits)
               (error 'read-message "CapTP frame exceeds the configured byte limit"))
             (define next-length (+ (* length 10) (- byte 48)))
             (when (> next-length max-frame-bytes)
               (error 'read-message "CapTP frame exceeds the configured byte limit"))
             (loop (read-byte in) next-length (add1 digit-count))]
            [(and (positive? digit-count) (= byte 58))
             (define payload (make-bytes length))
             (let fill ([offset 0])
               (if (= offset length)
                   payload
                   (let ([read (read-bytes! payload in offset length)])
                     (if (eof-object? read)
                         (error 'read-message "stream ended within a CapTP frame")
                         (fill (+ offset read))))))]
            [else
             (error 'read-message "invalid CapTP frame length")]))))

  (define (read-message unmarshallers)
    ;; OCapN frames messages as netstrings without a trailing comma. Syrup
    ;; bytestring framing has the same representation. Read the declared bytes
    ;; exactly because Syrup's outer bytestring reader accepts a short final read.
    (define framed (read-frame))
    (if (eof-object? framed)
        eof
        (syrup-decode framed #:unmarshallers unmarshallers)))

  (define (write-message msg marshallers)
    (syrup-write (syrup-encode msg #:marshallers marshallers) out)
    (flush-output out))

  (values read-message write-message))

(module+ test
  (require rackunit
           racket/port)

  (define-values (read-empty _write-empty)
    (captp-message-procs (open-input-bytes #"") (open-output-bytes)))
  (check-eq? (read-empty '()) eof)

  (define payload (list 'call 42))
  (define framed-out (open-output-bytes))
  (syrup-write (syrup-encode payload) framed-out)
  (define-values (read-one _write-one)
    (captp-message-procs
     (open-input-bytes (get-output-bytes framed-out))
     (open-output-bytes)))
  (check-equal? (read-one '()) payload)
  (check-eq? (read-one '()) eof)

  (define framed-bytes (get-output-bytes framed-out))
  (define fragmented-in
    (apply input-port-append #f
           (for/list ([byte (in-bytes framed-bytes)])
             (open-input-bytes (bytes byte)))))
  (define-values (read-fragmented _write-fragmented)
    (captp-message-procs fragmented-in (open-output-bytes)))
  (check-equal? (read-fragmented '()) payload)
  (check-eq? (read-fragmented '()) eof)

  (define-values (read-truncated _write-truncated)
    (captp-message-procs (open-input-bytes #"5:abc") (open-output-bytes)))
  (check-exn #rx"stream ended within a CapTP frame"
             (lambda () (read-truncated '())))

  (define-values (read-oversized _write-oversized)
    (captp-message-procs (open-input-bytes #"5:abcde")
                         (open-output-bytes)
                         #:max-frame-bytes 4))
  (check-exn #rx"exceeds the configured byte limit"
             (lambda () (read-oversized '()))))
