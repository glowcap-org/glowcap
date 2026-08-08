#lang racket/base
;; Goblins-canonical CapTP projection ops for interop wire send.
;;
;; Spritely Goblins 0.18.0 handles inbound `op:get` / `op:index` but has no
;; application-level outbound projection send yet (`captp.rkt` notes the missing
;; `<-hashmap-ref` operator). Interop scripts marshal the same record labels
;; Goblins already defines and write them on the live session through
;; `^tcp-netlayer`'s `interop-send`.

(require goblins/ocapn/define-recordable-struct
         syrup)

(provide make-op:get make-op:index make-op:listen
         make-desc:answer make-desc:import-object
         interop-marshallers)

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

(define-recordable-struct desc:import-object
  (pos)
  marshall::desc:import-object unmarshall::desc:import-object)

(define (make-desc:answer pos) (desc:answer pos))
(define (make-desc:import-object pos) (desc:import-object pos))
(define (make-op:get receiver-desc field-name new-answer-pos)
  (op:get receiver-desc field-name new-answer-pos))
(define (make-op:index receiver-desc index new-answer-pos)
  (op:index receiver-desc index new-answer-pos))
(define (make-op:listen to-desc listener-desc wants-partial?)
  (op:listen to-desc listener-desc wants-partial?))

(define interop-marshallers
  (list marshall::op:get
        marshall::op:index
        marshall::op:listen
        marshall::desc:answer
        marshall::desc:import-object))
