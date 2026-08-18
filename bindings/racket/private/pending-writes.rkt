#lang racket/base
;; Internal: the bounded outbound FIFO shared by byte-fed and loop-backed
;; sessions. Queue bytes, synchronization, and high-water admission have one
;; owner; transport pumping decides only when to fill or drain it.

(require racket/async-channel
         "constants.rkt")

(provide (all-defined-out))

(define PENDING-WRITE-HIGH-WATER (* 2 DEFAULT-FRAME-CAP))
(struct pending-writes (channel bytes lock high-water))

(define (make-pending-writes [high-water PENDING-WRITE-HIGH-WATER])
  (pending-writes (make-async-channel) (box 0) (make-semaphore 1) high-water))

(define (pending-writes-has-room? q)
  (call-with-semaphore
   (pending-writes-lock q)
   (lambda () (< (unbox (pending-writes-bytes q)) (pending-writes-high-water q)))))

(define (pending-writes-put-pair! q a b)
  (call-with-semaphore
   (pending-writes-lock q)
   (lambda ()
     (define next (+ (unbox (pending-writes-bytes q)) (bytes-length a) (bytes-length b)))
     (set-box! (pending-writes-bytes q) next)
     (async-channel-put (pending-writes-channel q) a)
     (async-channel-put (pending-writes-channel q) b)
     (< next (pending-writes-high-water q)))))

(define (pending-writes-try-get! q)
  (define out (async-channel-try-get (pending-writes-channel q)))
  (when out
    (call-with-semaphore
     (pending-writes-lock q)
     (lambda ()
       (set-box! (pending-writes-bytes q)
                 (max 0 (- (unbox (pending-writes-bytes q)) (bytes-length out)))))))
  out)

(define (pending-writes-clear! q)
  ;; Teardown owns every staged byte the writer did not already take.
  (let loop ()
    (when (pending-writes-try-get! q) (loop))))
