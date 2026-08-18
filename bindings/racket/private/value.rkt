#lang racket/base
;; Internal: the public value vocabulary — the reference and event structs the
;; marshalling, the vat, and the session surface exchange as native Racket
;; values. Pure data; imports nothing. `pancake.rkt` re-provides the public
;; subset.

(provide (all-defined-out))

;; One Host-scoped capability identity. Near/far and object/promise are wire
;; projection details owned by PancakeHost; a binding must not mirror them.
;; `released?` prevents an application from reusing a handle after returning
;; its retain to the Host.
(struct ref (id [released? #:auto #:mutable])
  #:transparent
  #:constructor-name make-ref/internal
  ;; One projected occurrence owns one retain, so two Equal capabilities may
  ;; be distinct structs with independent release flags. OCapN Target equality
  ;; follows the immutable Host id and cannot change when either occurrence is
  ;; released.
  #:property prop:equal+hash
  (list (lambda (a b _recur) (= (ref-id a) (ref-id b)))
        (lambda (a recur) (recur (ref-id a)))
        (lambda (a recur) (recur (ref-id a)))))
(struct sym (value) #:transparent)             ; tag a string as an OCapN symbol
(struct kw (value) #:transparent)              ; an OCapN keyword
(struct error-arg (message) #:transparent)     ; a fulfilled OCapN Error value
(struct pset (items) #:transparent)             ; an OCapN set
(struct tagged-arg (tag value) #:transparent)   ; an OCapN tagged record
(struct struct-arg (entries) #:transparent)     ; unique String key/value pairs

;; The typed cause of a connection's most recent refused frame, carried on the
;; `abort` field of the `exn:fail:pancake` the feeding path raises. `domain` is
;; 'codec, 'session, or 'foreign; `kind` is the wire name of the projected
;; op:abort kind, or #f when none was projected; `message` is the static
;; diagnostic, `error-name` the originating error, and
;; `abort-delivery-error-name` a failure publishing the terminal abort, and
;; `secondary-error-name` / `secondary-error-count` the bounded cleanup or
;; consequence failures that followed the originating error.
(struct abort-info (domain kind message error-name abort-delivery-error-name
                           secondary-error-name secondary-error-count) #:transparent)

;; What a session's handshake reports about its partner. `session-key` is the
;; partner's fresh session public key, `designator` is the location designator
;; claimed under that session signature (a string, empty when its location
;; carried none), and
;; `locator-record` is the verbatim <ocapn-peer> record those were read from
;; (empty when the session captured none). `session-partner-identity` builds
;; one, and only ever after the signature over that location record verified,
;; so the claim is bound to the session key. That signature does not prove
;; control of the durable designator; `provenance` records channel proof.
(struct partner-identity (session-key designator locator-record provenance) #:transparent)

;; How a partner's advertised durable identity was authenticated, the third
;; fact `partner-identity` reports beside session key and designator
;; (ADR-0097, ADR-0105). The answer is a property of the connection rather than
;; of its transport name: the same transport symbol reaches this peer over code
;; that can prove something and code that cannot, so no list of transports
;; belongs here. Either 'authenticated-transport (the code that realized this
;; connection verified the far end of the byte channel holds a durable key, and
;; the partner claimed that same key), or 'unauthenticated (no durable identity
;; was proved).
;;
;; Ask `partner-identity-durable-authenticated?` when an operation needs a
;; proved durable peer. The fresh session key and durable designator are
;; independent values.
(define (partner-identity-durable-authenticated? id)
  (not (eq? (partner-identity-provenance id) 'unauthenticated)))
