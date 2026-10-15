#lang racket/base
;; Internal: bounded Session establishment over a byte channel already chosen
;; by a transport companion. FFI handshake semantics stay in the Host; this
;; leaf owns establishment/cleanup choreography and exact error retention.

(require ffi/unsafe
         "../constants.rkt"
         "../ffi-host.rkt"
         "../errors.rkt"
         "../locator.rkt"
         "../async.rkt"
         (only-in "../vat.rkt" converts-to-broken?)
         "../host/state.rkt"
         "../pump.rkt"
         "../session.rkt"
         "state.rkt"
         "identity.rkt")

(provide (all-defined-out))

;; Drive a freshly opened connection's keyed handshake to an open session,
;; abandoning the connection on any failure so a rude partner costs one
;; accept, never the listener. `timeout-ms` bounds the wait; #f and 0 leave it
;; unbounded. The read/feed loop lives in `run-handshake!`.
(define (retain-establishment-cleanup! m primary cleanup)
  (define retained (retain-cleanup-failure primary cleanup))
  (when (eq? retained primary)
    ;; An arbitrary foreign exception cannot carry Racket's immutable typed
    ;; fields. Its cleanup has no return slot, so the Host becomes its owner.
    (record-host-runtime-failure! m cleanup))
  retained)

(define (finish-establish! c timeout-ms)
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (define retained error)
                     (with-handlers ([(lambda (_) #t)
                                      (lambda (cleanup-error)
                                        (set! retained
                                              (retain-establishment-cleanup!
                                               (session-host c) retained cleanup-error)))])
                       (abandon-session! c))
                     (raise retained))])
    (run-handshake! c timeout-ms)
    c))

;; A failed mint/handshake closes its byte channel before the error escapes.
;; Every transport close is idempotent, so a surviving Session remains safe.
(define (establish-closing-transport m transport thunk)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (define retained e)
                     (with-handlers ([(lambda (_) #t)
                                      (lambda (cleanup-error)
                                        (set! retained
                                              (retain-establishment-cleanup!
                                               m retained cleanup-error)))])
                       ((async-transport-close! transport)))
                     (raise retained))])
    (thunk)))

;; Mint the dialing half over a byte channel the caller already realized for
;; `loc`. Binding-internal. The transport seam companions call this with a
;; loop-driven transport (iroh) or a just-opened socket. The locator travels
;; whole; the host retains its own dial default for the transport, so no
;; locator policy lives here.
;; The handshake is bounded by default, the same `HANDSHAKE-TIMEOUT-MS` the
;; accepted half below uses and the same bound the Rust, Python, and TypeScript
;; dials carry: a partner that takes the connection and then never finishes the
;; handshake is a hang, not a slow success. A caller that holds its own
;; cancellation passes #f (or 0) to wait forever.
(define (establish-dialed-locator-session m loc transport
                                             #:time-travel? [time-travel? #f]
                                             #:verified-channel-key
                                             [verified-channel-key #f]
                                             #:handshake-timeout-ms
                                             [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (establish-closing-transport m transport
    (lambda ()
      (define c
        (call-with-locator-view loc
          (lambda (view)
            (call-with-host m
              (lambda ()
                (define-values (rc ptr)
                  (glowcap_host_session_open_dialed_locator (host-ptr m) view))
                (check/host rc)
                (build-session m ptr transport time-travel?))))))
      ;; Before the first partner byte, which is the only window a realizer's
      ;; proof can be weighed in.
      (when verified-channel-key
        (session-bind-verified-channel-key! c verified-channel-key))
      (finish-establish! c handshake-timeout-ms))))

;; Mint the accepting half over a connection the caller's own listener
;; produced. `server-designator` is the listener's signing designator (key for
;; keyed-tcp/iroh; unused for tcp); `accepted-local-addr` is what accept
;; reported. The host resolves what this accept signs and retains it without
;; displacing an explicitly selected advertised locator (ADR-0078); no locator
;; policy lives in this binding. The handshake is bounded by default: see
;; `accept-next-session`, which every listening surface goes through.
(define (establish-accepted-session m transport-name server-designator transport
                                       #:accepted-local-addr [accepted-local-addr ""]
                                       #:designator-scheme [designator-scheme #f]
                                       #:time-travel? [time-travel? #f]
                                       #:verified-channel-key
                                       [verified-channel-key #f]
                                       #:handshake-timeout-ms
                                       [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (establish-closing-transport m transport
    (lambda ()
      (define tb (string->bytes/utf-8 transport-name))
      (define sb (string->bytes/utf-8 server-designator))
      (define lb (string->bytes/utf-8 accepted-local-addr))
      (define c
        (call-with-host m
          (lambda ()
            ;; Pin once: open_accepted borrows these for the call.
            (define tpin (pin-immobile tb))
            (define spin (pin-immobile sb))
            (define lpin (pin-immobile lb))
            (unless designator-scheme
              (raise-glowcap 'establish-accepted-session ERR-INVALID-ARGUMENT
                             "accepted byte-channel provider must declare its designator scheme"))
            (define-values (rc ptr)
              (glowcap_host_session_open_accepted (host-ptr m)
                                                   tpin (bytes-length tb)
                                                   designator-scheme
                                                   spin (bytes-length sb)
                                                   lpin (bytes-length lb)))
            (check/host rc)
            (build-session m ptr transport time-travel?))))
      ;; Before the first partner byte, which is the only window a realizer's
      ;; proof can be weighed in.
      (when verified-channel-key
        (session-bind-verified-channel-key! c verified-channel-key))
      (finish-establish! c handshake-timeout-ms))))

;; The one accept rule every listening surface shares (tcp, keyed-tcp, and
;; iroh) all reach the wire through here. `next-partner` blocks for the next
;; partner and returns two values: its `async-transport` and the local address
;; accept reported.
;;
;; Both halves of the rule protect the listener from a partner it did not
;; choose. A rude probe (connect and hang up, a port scan, a key mismatch)
;; fails its own handshake, and a partner that connects and then says nothing
;; never fails at all, so only `HANDSHAKE-TIMEOUT-MS` ends that wait. Either
;; costs this one accept and the loop moves to the next partner, matching the
;; Rust, Python, and TypeScript listeners; without both, one probe parks or
;; ends a server's accept loop. A skipped partner leaves nothing behind:
;; `establish-closing-transport` closes its transport exactly once on the way
;; out, whether the handshake failed or timed out.
;;
;; The handler predicate is `converts-to-broken?`, not a catch-all, so a
;; `break-thread` aimed at the accepting thread still terminates it instead of
;; being absorbed into a retry. What `next-partner` itself raises (a closed
;; listener) propagates: that ends the loop, as it should.
(define (accept-next-session m transport-name server-designator next-partner
                                #:designator-scheme [designator-scheme #f]
                                #:time-travel? [time-travel? #f]
                                #:handshake-timeout-ms
                                [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (let loop ()
    ;; Three facts come out of an accept: the byte channel, where it came from,
    ;; and what the code that accepted it proved about the far end (`#f` on a
    ;; socket, which proves nothing; an endpoint id on iroh).
    (define-values (transport accepted-local-addr verified-channel-key)
      (next-partner))
    (define c
      (with-handlers ([converts-to-broken? (lambda (_e) #f)])
        (establish-accepted-session m transport-name server-designator transport
                                       #:accepted-local-addr accepted-local-addr
                                       #:designator-scheme designator-scheme
                                       #:time-travel? time-travel?
                                       #:verified-channel-key verified-channel-key
                                       #:handshake-timeout-ms handshake-timeout-ms)))
    (or c (loop))))
