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
  #:constructor-name make-ref/internal)
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

;; Who a session is talking to, as its handshake proved it. `session-key` is
;; the partner's session public key, `designator` is the location designator
;; the partner signed (a string, empty when its location carried none), and
;; `locator-record` is the verbatim <ocapn-peer> record those were read from
;; (empty when the session captured none). `session-partner-identity` builds
;; one, and only ever after the signature over that location record verified,
;; so the designator here is bound to the key beside it.
(struct partner-identity (session-key designator locator-record provenance) #:transparent)

;; How a partner's advertised durable identity was authenticated, the third
;; fact `partner-identity` reports beside session key and designator
;; (ADR-0097). One of 'authenticated-transport (the transport layer proved the
;; partner's durable key: iroh's QUIC handshake, or WebRTC's DTLS binding under
;; capability-authorized signaling), 'durable-key-attestation (the hello
;; carried a session-key-attestation signed by the durable key its designator
;; names and it verified — static authorization, not proof the signer is live
;; on this connection), or 'unauthenticated (no durable identity was proved).
;;
;; Ask `partner-identity-durable-authenticated?` when an operation needs a
;; proved durable peer; never compare the designator against the session key,
;; which is a coincidence of today's key reuse.
(define (partner-identity-durable-authenticated? id)
  (not (eq? (partner-identity-provenance id) 'unauthenticated)))
