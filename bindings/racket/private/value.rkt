#lang racket/base
;; Internal: the public value vocabulary — the reference and event structs the
;; marshalling, the vat, and the connection surface exchange as native Racket
;; values. Pure data; imports nothing. `pancake.rkt` re-provides the public
;; subset.

(provide (all-defined-out))

(struct near-ref (id promise) #:transparent)   ; a local export this peer hosts
(struct far-ref (id promise) #:transparent)    ; a partner-hosted import this peer holds
(struct promise-ref (answer) #:transparent)
(struct sturdy () #:transparent)
(struct broken () #:transparent)
(struct sym (value) #:transparent)             ; tag a string as an OCapN symbol
(struct kw (value) #:transparent)              ; an OCapN keyword
(struct pset (items) #:transparent)             ; an OCapN set
(struct tagged-arg (tag value) #:transparent)   ; an OCapN tagged record

;; The typed cause of a connection's most recent refused frame, carried on the
;; `abort` field of the `exn:fail:pancake` the feeding path raises. `domain` is
;; 'codec, 'session, or 'foreign; `kind` is the wire name of the projected
;; op:abort kind, or #f when none was projected; `message` is the static
;; diagnostic and `error-name` the originating error.
(struct abort-info (domain kind message error-name) #:transparent)

;; near/far take an optional promise? flag.
(define (near id [promise #f]) (near-ref id promise))
(define (far id [promise #f]) (far-ref id promise))
