#lang racket/base
;; Process-surviving diagnostics for failures observed after their native
;; lifecycle owner has already been collected.

(require "constants.rkt"
         "errors.rkt")

(provide (struct-out failure-event)
         record-runtime-failure!
         run-native-finalizer!
         take-runtime-failures!)

(struct failure-event
  (sequence dropped-before layer scope scope-id operation-id
            primary-result secondary-result secondary-count truncated-fields
            operation primary-name primary-message secondary-name secondary-message)
  #:transparent)

(define capacity DEFAULT-FAILURE-CAPACITY)
(define payload-cap DEFAULT-FAILURE-PAYLOAD-CAP)
(define u64-max #xffffffffffffffff)
(define gate (make-semaphore 1))
(define failures (make-vector capacity #f))
(define head 0)
(define count 0)
(define next-sequence 1)

(define (failure-name value)
  (format "~a" (or (object-name value) 'raised-value)))

(define (failure-message value)
  (if (exn? value) (exn-message value) (format "~a" value)))

(define (stable-result value)
  (if (and (exact-integer? value) (<= ERR-TIMEOUT value OK))
      value
      ERR-INTERNAL))

(define (bounded-fields fields)
  (let loop ([pending fields] [remaining payload-cap] [index 0]
             [retained '()] [flags 0])
    (cond
      [(null? pending) (values (reverse retained) flags)]
      [else
       (define encoded (string->bytes/utf-8 (car pending)))
       (define-values (text copied)
         (let loop ([copied (min remaining (bytes-length encoded))])
           (with-handlers ([exn:fail? (lambda (_) (loop (sub1 copied)))])
             (values (bytes->string/utf-8 (subbytes encoded 0 copied) #f)
                     copied))))
       (loop (cdr pending)
             (- remaining copied)
             (add1 index)
             (cons text retained)
             (if (= copied (bytes-length encoded))
                 flags
                 (bitwise-ior flags (arithmetic-shift 1 index))))])))

(define (record-runtime-failure! layer operation error)
  (call-with-semaphore
   gate
   (lambda ()
     (when (= count capacity)
       (define dropped (vector-ref failures head))
       (vector-set! failures head #f)
       (set! head (modulo (add1 head) capacity))
       (set! count (sub1 count))
       (when (> count 0)
       (define first (vector-ref failures head))
         (vector-set!
          failures head
          (struct-copy failure-event first
                       [dropped-before
                        (min u64-max
                             (+ (failure-event-dropped-before first)
                                (failure-event-dropped-before dropped)
                                1))]))))
     (define glowcap-error? (exn:fail:glowcap? error))
     (define secondary-count
       (if glowcap-error? (exn:fail:glowcap-secondary-count error) 0))
     (define secondary-result
       (if (positive? secondary-count)
           (stable-result (exn:fail:glowcap-secondary-code error))
           OK))
     (define secondary-name
       (if (positive? secondary-count)
           (exn:fail:glowcap-secondary-name error)
           ""))
     (define-values (texts truncated-fields)
       (bounded-fields
        (list operation (failure-name error) (failure-message error)
              secondary-name "")))
     (define tail (modulo (+ head count) capacity))
     (vector-set!
      failures tail
      (failure-event next-sequence 0 layer 'process 0 0
                     (if glowcap-error?
                         (stable-result (exn:fail:glowcap-code error))
                         ERR-INTERNAL)
                     secondary-result secondary-count truncated-fields
                     (list-ref texts 0) (list-ref texts 1) (list-ref texts 2)
                     (list-ref texts 3) (list-ref texts 4)))
     (set! next-sequence (min (add1 next-sequence) u64-max))
     (set! count (add1 count)))))

(define (run-native-finalizer! operation release #:layer [layer 'binding])
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (record-runtime-failure! layer operation error)
                     (void))])
    (release)))

(define (take-runtime-failures!)
  (call-with-semaphore
   gate
   (lambda ()
     (define claimed
       (for/list ([offset (in-range count)])
         (define index (modulo (+ head offset) capacity))
         (begin0 (vector-ref failures index)
           (vector-set! failures index #f))))
     (set! head 0)
     (set! count 0)
     claimed)))
