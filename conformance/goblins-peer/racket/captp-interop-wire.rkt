#lang racket/base
;; Test-only CapTP request adapters and resolver-release observation.
;;
;; Spritely Goblins 0.18.0 handles inbound `op:get` / `op:index` but has no
;; application-level outbound projection send (`captp.rkt` notes the missing
;; `<-hashmap-ref` operator), and it writes a promise it passes as
;; `desc:import-promise`, never as `desc:answer` in argument position. Interop
;; scripts translate ordinary Goblins requests after questions and resolvers
;; have been allocated. They preserve both names and the resolver export count.
;; Goblins handles every reply. The release watch orders a later health call
;; after the GC frames, never decides whether a vow settled.

(require goblins/ocapn/define-recordable-struct
         racket/async-channel)

(provide make-op:deliver make-op:get make-op:index make-op:listen
         make-desc:answer
         interop-marshallers
         record-label record-field deliver-verb deliver-answer-and-resolver
         make-resolver-gc-watch)

(define-recordable-struct op:deliver
  (to-desc args answer-pos resolve-me-desc)
  marshall::op:deliver unmarshall::op:deliver)

(define-recordable-struct op:get
  (receiver-desc field-name new-answer-pos)
  marshall::op:get unmarshall::op:get)

(define-recordable-struct op:index
  (receiver-desc index new-answer-pos)
  marshall::op:index unmarshall::op:index)

(define-recordable-struct op:listen
  (to-desc listener-desc wants-partial?)
  marshall::op:listen unmarshall::op:listen)

(define-recordable-struct desc:answer
  (pos)
  marshall::desc:answer unmarshall::desc:answer)

(define (make-desc:answer pos) (desc:answer pos))
(define (make-op:deliver to-desc args answer-pos resolve-me-desc)
  (op:deliver to-desc args answer-pos resolve-me-desc))
(define (make-op:get receiver-desc field-name new-answer-pos)
  (op:get receiver-desc field-name new-answer-pos))
(define (make-op:index receiver-desc index new-answer-pos)
  (op:index receiver-desc index new-answer-pos))
(define (make-op:listen to-desc listener-desc wants-partial?)
  (op:listen to-desc listener-desc wants-partial?))

(define interop-marshallers
  (list marshall::op:deliver
        marshall::op:get
        marshall::op:index
        marshall::op:listen
        marshall::desc:answer))

;; The label of a Goblins record struct, such as "op:deliver", or #f when the
;; value is not a struct.
(define (record-label obj)
  (and (struct? obj)
       (let* ([vec (struct->vector obj)]
              [raw (and (> (vector-length vec) 0) (vector-ref vec 0))]
              [text (format "~a" raw)])
         (cond
           [(regexp-match #rx"^struct:(.+)$" text) => cadr]
           [else text]))))

;; Field `idx` of a record struct, counting the label as field 0.
(define (record-field obj idx)
  (define vec (struct->vector obj))
  (and (> (vector-length vec) idx) (vector-ref vec idx)))

;; A string, byte string, or symbol payload as text, or #f for anything else.
(define (payload->text payload)
  (cond
    [(string? payload) payload]
    [(bytes? payload) (bytes->string/latin-1 payload)]
    [(symbol? payload) (symbol->string payload)]
    [else #f]))

(define (deliver-verb msg)
  (and (equal? (record-label msg) "op:deliver")
       (let ([args (record-field msg 2)])
         (and (pair? args) (payload->text (car args))))))

;; Refuse fixture mistakes before replacing a request. These are Goblins' own
;; allocated names, and export zero cannot serve as an application resolver.
(define (deliver-answer-and-resolver msg)
  (define answer (record-field msg 3))
  (define resolver (record-field msg 4))
  (unless (and (exact-nonnegative-integer? answer)
               (equal? (record-label resolver) "desc:import-object")
               (exact-positive-integer? (record-field resolver 1)))
    (error 'interop-request "expected a Goblins question and application resolver"))
  (values answer resolver))

;; Writer and reader run on different threads. Register before emitting a
;; translated request. Signal once all its resolver occurrences were returned.
;; The subsequent ordinary call makes Goblins process those GC messages before
;; it can dispatch the health reply on the same ordered input stream.
(define (make-resolver-gc-watch expected-count)
  (define lock (make-semaphore 1))
  (define outstanding (make-hasheqv))
  (define registered 0)
  (define released (make-async-channel))
  (define reported #f)
  (define (register resolver)
    (call-with-semaphore
     lock
     (lambda ()
       (define pos (record-field resolver 1))
       (set! registered (add1 registered))
       (hash-set! outstanding pos (add1 (hash-ref outstanding pos 0))))))
  (define (observe msg)
    (when (equal? (record-label msg) "op:gc-exports")
      (call-with-semaphore
       lock
       (lambda ()
         (for ([pos (in-list (record-field msg 1))]
               [delta (in-list (record-field msg 2))])
           (when (hash-has-key? outstanding pos)
             (hash-set! outstanding pos (- (hash-ref outstanding pos) delta))))
         (when (and (= registered expected-count)
                    (for/and ([count (in-hash-values outstanding)]) (zero? count))
                    (not reported))
           (set! reported #t)
           (async-channel-put released 'released))))))
  (values register observe released))

(module+ test
  (require rackunit)
  (struct desc:import-object (position) #:transparent)
  (struct op:gc-exports (positions deltas) #:transparent)
  (define-values (register observe released) (make-resolver-gc-watch 2))
  (register (desc:import-object 12))
  (observe (op:gc-exports '(12) '(1)))
  (check-false (sync/timeout 0 released) "one resolver does not prove both releases")
  (register (desc:import-object 19))
  (observe (op:gc-exports '(0 22) '(1 1)))
  (check-false (sync/timeout 0 released) "unrelated releases do not advance the barrier")
  (observe (op:gc-exports '(19) '(1)))
  (check-equal? (sync/timeout 0 released) 'released)
  (observe (op:gc-exports '(19) '(1)))
  (check-false (sync/timeout 0 released) "the barrier signals only once")
  (define-values (register-over observe-over released-over) (make-resolver-gc-watch 1))
  (register-over (desc:import-object 12))
  (observe-over (op:gc-exports '(12) '(2)))
  (check-false (sync/timeout 0 released-over) "over-release is not successful cleanup")
  (check-exn #rx"application resolver"
             (lambda ()
               (deliver-answer-and-resolver
                (make-op:deliver #f '() 1 (desc:import-object 0))))))
