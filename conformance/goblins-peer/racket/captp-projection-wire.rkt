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

(provide make-op:get make-op:index make-desc:answer interop-marshallers)

(define-recordable-struct op:get
  (receiver-desc field-name new-answer-pos)
  marshall::op:get unmarshall::op:get)

(define-recordable-struct op:index
  (receiver-desc index new-answer-pos)
  marshall::op:index unmarshall::op:index)

(define-recordable-struct desc:answer
  (pos)
  marshall::desc:answer unmarshall::desc:answer)

(define (make-desc:answer pos) (desc:answer pos))
(define (make-op:get receiver-desc field-name new-answer-pos)
  (op:get receiver-desc field-name new-answer-pos))
(define (make-op:index receiver-desc index new-answer-pos)
  (op:index receiver-desc index new-answer-pos))

(define interop-marshallers
  (list marshall::op:get
        marshall::op:index
        marshall::desc:answer))
