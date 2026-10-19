#lang racket/base
;; Internal: exporter-location and authenticated partner identity projection for
;; a Session. This leaf borrows FFI views only for each call and lifts them
;; into Racket-owned values before returning.

(require ffi/unsafe
         "../constants.rkt"
         "../abi-value.rkt"
         "../ffi-host.rkt"
         "../errors.rkt"
         "../value.rkt"
         "../locator.rkt"
         "../host/state.rkt"
         "state.rkt")

(provide (all-defined-out))

;; Record the complete dialable exporter location this session's gifter embeds
;; in a give (ADR-0039). `#f` restores the partner's signed location.
(define (session-set-exporter-locator! c loc)
  (define (apply-view! view)
    (call-with-host (session-host c)
      (lambda ()
        (check/host (glowcap_host_session_set_exporter_location
                     (session-ptr c) view)))))
  (if loc (call-with-locator-view loc apply-view!) (apply-view! #f)))

;; Who this session's partner proved itself to be, as a `partner-identity`: the
;; partner's session public key, the location designator it signed, and the
;; verbatim location record those were read from.
;;
;; Getting an answer here always means the signature was checked. A keyed
;; `op:start-session` carries an Ed25519 signature over the partner's whole
;; location record, and the engine verifies that signature before the session
;; opens, so the designator this returns is bound to the key beside it by the
;; same signature. That is what lets a server refuse a caller claiming a
;; locator it does not own: compare the locator the caller hands you against
;; the designator here, and turn the call away when the two disagree.
;;
;; The library lends these bytes for as long as the session lives, so each view
;; is copied into a fresh Racket value before this returns. It raises while the
;; partner's `op:start-session` has not arrived with a key yet, and it raises on
;; a session opened without partner verification, because there is no proved
;; identity to read on one.
(define (session-partner-identity c)
  (guard-open 'session-partner-identity c)
  (call-with-host (session-host c)
    (lambda ()
      (define out (make-GlowcapPartnerIdentity #f 0 #f 0 #f 0 0))
      (check/host (glowcap_host_session_partner_identity (session-ptr c) out))
      (partner-identity
       (bytes<-c (GlowcapPartnerIdentity-session-key out)
                 (GlowcapPartnerIdentity-session-key-len out))
       (bytes->string/utf-8
        (bytes<-c (GlowcapPartnerIdentity-designator out)
                  (GlowcapPartnerIdentity-designator-len out))
        #\uFFFD)
       (bytes<-c (GlowcapPartnerIdentity-locator-record out)
                 (GlowcapPartnerIdentity-locator-record-len out))
       (provenance<-abi (GlowcapPartnerIdentity-provenance out))))))

;; Testify what proved this connection's far end, when your own transport proved
;; one.
;;
;; glowcap does not open your sockets, so it cannot see what opening them
;; established. An iroh connection completes only with the holder of the node id
;; you dialed or accepted, and that is a stronger fact than anything a partner
;; can claim about itself, but only you hold it. Pass the node id here and
;; `session-partner-identity` reports `authenticated-transport`; withhold it and
;; the same session reports `unauthenticated`.
;;
;; `designator` is that identity as a locator writes it, which is exactly what
;; the iroh transport's remote node id hands you.
;;
;; Call it after opening the session and before feeding the first byte from the
;; partner. It raises afterwards, because by then the handshake this evidence
;; was for has already been judged. Naming a second, different identity raises
;; too: one connection has one far end. Naming the same one twice is the same
;; statement made twice and is fine.
(define (session-bind-verified-channel-key! c designator)
  (guard-open 'session-bind-verified-channel-key! c)
  (define raw (string->bytes/utf-8 designator))
  (call-with-host (session-host c)
    (lambda ()
      (check/host (glowcap_host_session_bind_verified_channel_key
                   (session-ptr c) (pin-immobile raw) (bytes-length raw))))))
