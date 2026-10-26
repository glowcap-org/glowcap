#lang racket/base
;; Goblins-canonical CapTP records for interop wire send.
;;
;; Spritely Goblins 0.18.0 handles inbound `op:get` / `op:index` but has no
;; application-level outbound projection send (`captp.rkt` notes the missing
;; `<-hashmap-ref` operator), and it writes a promise it passes as
;; `desc:import-promise`, never as `desc:answer` in argument position. Interop
;; scripts marshal the same record labels Goblins already defines and write
;; them on the live session through `^tcp-netlayer`'s `interop-send`. The
;; readers at the end let a script inspect the records Goblins wrote or
;; received.

(require goblins/ocapn/define-recordable-struct
         syrup)

(provide make-op:deliver make-op:get make-op:index make-op:listen
         make-desc:answer make-desc:export make-desc:import-object
         interop-marshallers
         record-label record-field export-desc-pos payload->text)

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

(define-recordable-struct desc:export
  (pos)
  marshall::desc:export unmarshall::desc:export)

(define-recordable-struct desc:import-object
  (pos)
  marshall::desc:import-object unmarshall::desc:import-object)

(define (make-desc:answer pos) (desc:answer pos))
(define (make-desc:export pos) (desc:export pos))
(define (make-desc:import-object pos) (desc:import-object pos))
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
        marshall::desc:answer
        marshall::desc:export
        marshall::desc:import-object))

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

;; The position a `desc:export` names, or #f for any other descriptor.
(define (export-desc-pos desc)
  (and (equal? (record-label desc) "desc:export")
       (record-field desc 1)))

;; A string, byte string, or symbol payload as text, or #f for anything else.
(define (payload->text payload)
  (cond
    [(string? payload) payload]
    [(bytes? payload) (bytes->string/latin-1 payload)]
    [(symbol? payload) (symbol->string payload)]
    [else #f]))
