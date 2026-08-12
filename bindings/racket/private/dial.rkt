#lang racket/base
;; The dial executor (binding spine Pass 3c): one path that turns a parsed
;; locator into an open, handshaken `session`, shared by `connect` and
;; handoff-redeem alike.
;;
;; Every dial decision — the host:port grammar, the direct-addresses hint rule,
;; the peer-id reachability posture, the scheme dispatch, and the typed errors —
;; is resolved once in the core by `pancake_host_plan_dial`, which hands back a
;; `PancakeDialPlan`. This module holds no dial business logic: it marshals the
;; posture, reads the plan into a language sum, and performs the one thing the
;; core cannot — the byte-channel open (`tcp-connect`, or the iroh companion).
;; Adding a transport is a core change, not an edit here. Session owns
;; mint/handshake (`establish-dialed-locator-session` /
;; `establish-accepted-session`); this module owns plan + channel open + the
;; public `connect` dialer.
;;
;; Lazy-require breaks the session ↔ dial cycle: dial lazy-requires session
;; for establish / serve / drain choreography; the public barrel
;; (`pancake.rkt`) requires dial directly.

(require ffi/unsafe
         racket/tcp
         racket/lazy-require
         "constants.rkt"
         "iroh-companion.rkt"
         "ffi-host.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "vat.rkt"
         "locator.rkt"
         "async.rkt"
         "host.rkt"
         (only-in "codec.rkt" feature-mask)
         "action.rkt"
         ;; The handshake bound lives with the deadline machinery it feeds, so
         ;; the dial and the accept rule spell their default with one constant.
         (only-in "pump.rkt" HANDSHAKE-TIMEOUT-MS))

(lazy-require
 ;; The WebSocket client loads only when a keyed-relay dial runs, so a minimal
 ;; install without rfc6455 pays nothing until it asks for a rendezvous.
 ["ws-transport.rkt" (ws-transport)]
 ;; The native loop tier (ADR-0112) loads only when a native provider dial
 ;; actually rides it; only the bare-locator Host fallback stays byte-fed.
 ["loop.rkt"
 (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   loop-connect-session)]
 ["tcp-provider.rkt" (driver-loop-add-tcp!)]
 ["relay-provider.rkt"
  (driver-loop-add-relay!
   locator-relay-route
   relay-dial-url)]
 ["session.rkt"
  (establish-dialed-locator-session
   session-close!
   session-serve
   session-ptr
   session-owns-host?
   with-host-drain)])

(provide (struct-out host-port-dial)
         (struct-out peer-id-dial)
         (struct-out rendezvous-dial)
         (struct-out signaling-dial)
         plan-dial
         dial-parsed-locator
         dial-exporter
         run-dial!
         connect)

;; ── The dial executor (a DIAL action's binding half) ─────────────────────────
;; The host asks for a dial with a ticket only; the executor borrows the
;; complete pending locator via `pancake_host_pending_dial` (no URI re-parse), then dials.
;; Which netlayer answers — and under which reachability posture — is the
;; binding's decision, never the ABI's. A `tcp` locator dials its host:port; an
;; `iroh` locator with a direct-address hint dials it relay-less (Direct), and a
;; bare node id resolves under the host's configured redeem posture (default Discovery;
;; `set-host-redeem-reachability!` lowers it), so one give shape covers an
;; offline direct dial and an internet dial-by-id alike. The iroh companion
;; loads on demand, only for an iroh give; `iroh-companion.rkt` owns where it
;; lives and loads it exactly once even when several threads dial at once.

;; A resolved dial from `pancake_host_plan_dial`: language sum over the C
;; shape flag (mirrors Zig DialPlan). Plan views alias the pinned input
;; buffers; decode those subslices only — a non-alias is a contract break.
(struct host-port-dial (host port) #:transparent)
(struct peer-id-dial (addresses reach-kind reach-value) #:transparent)
;; A keyed-relay locator names a peer with no dialable address: the byte path
;; is the relay rendezvous bridge the dialing host is configured for (ADR-0088).
(struct rendezvous-dial () #:transparent)
(struct signaling-dial () #:transparent)

;; `sources` pairs each pinned base pointer with the Racket bytes it copied,
;; so the alias arithmetic runs on addresses the collector cannot move.
(define (decode-plan-view sources ptr len)
  (cond
    [(or (not ptr) (= len 0)) ""]
    [else
     (define vp (cast ptr _pointer _uintptr))
     (or (for/or ([src (in-list sources)])
           (define base (cast (car src) _pointer _uintptr))
           (define bs (cdr src))
           (and (<= base vp)
                (<= (+ vp len) (+ base (bytes-length bs)))
                (bytes->string/utf-8
                 (subbytes bs (- vp base) (+ (- vp base) len))
                 #\uFFFD)))
         (raise-pancake 'plan-dial ERR-INVALID-ARGUMENT
                        "dial plan view does not alias input buffers"))]))

(define (plan-dial transport designator addrs policy value)
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define hb (string->bytes/utf-8 addrs))
  ;; Pin before the call and hold the pins across the view decode: the plan's
  ;; views alias these buffers, and a collection between call and decode
  ;; would move an unpinned bytevector out from under the returned addresses.
  (define dpin (pin-immobile db))
  (define hpin (pin-immobile hb))
  (define plan (make-PancakeDialPlan 0 #f 0 0 #f 0 0 0))
  (check/host (pancake_host_plan_dial (pin-immobile tb) (bytes-length tb)
                                      dpin (bytes-length db)
                                      hpin (bytes-length hb) policy value plan))
  (define sources (list (cons dpin db) (cons hpin hb)))
  (define shape (PancakeDialPlan-shape plan))
  (cond
    [(= shape DIAL-SHAPE-PEER-ID)
     (peer-id-dial
      (decode-plan-view sources (PancakeDialPlan-addresses plan) (PancakeDialPlan-addresses-len plan))
      (PancakeDialPlan-reach-kind plan)
      (PancakeDialPlan-reach-value plan))]
    [(= shape DIAL-SHAPE-HOST-PORT)
     (host-port-dial
      (decode-plan-view sources (PancakeDialPlan-host plan) (PancakeDialPlan-host-len plan))
      (PancakeDialPlan-port plan))]
    [(= shape DIAL-SHAPE-SIGNALING) (signaling-dial)]
    [(= shape DIAL-SHAPE-RENDEZVOUS) (rendezvous-dial)]
    [else (raise-pancake 'plan-dial ERR-INVALID-ARGUMENT
                         "unknown dial shape ~a" shape)]))

;; The one dial path for `connect` and handoff redeem alike: no dispatch, no
;; grammar, no posture — the core resolves all of that in `pancake_host_plan_dial`,
;; and this opens the byte channel it names. `handshake-timeout-ms` bounds the
;; keyed handshake that follows the channel open, the same bound the accept rule
;; carries; #f (or 0) waits forever.
(define (dial-parsed-locator m loc
                             #:reachability [reach #f]
                             #:redeem? [redeem? #f]
                             #:handshake-timeout-ms
                             [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (define-values (policy value)
    (cond [redeem? (values DIAL-POSTURE-REDEEM 0)]
          [reach (values DIAL-POSTURE-EXPLICIT reach)]
          [else (values DIAL-POSTURE-EXPLICIT-NONE 0)]))
  (define transport (locator-transport loc))
  (define designator (locator-designator loc))
  (define addrs (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES ""))
  (define plan (plan-dial transport designator addrs policy value))
  (cond
    [(peer-id-dial? plan)
     (define reach-kind (peer-id-dial-reach-kind plan))
     (define reach*
       (cond [(= reach-kind DIAL-REACH-DIRECT) (iroh-ref 'IROH-REACH-DIRECT)]
             [(= reach-kind DIAL-REACH-CONFIGURED) (host-redeem-reachability-value m)]
             [else (peer-id-dial-reach-value plan)]))
     (if (host-loop-of m)
         (dial-shared-loop m (host-loop-of m) loc reach*
                           #:redeem? redeem?
                           #:plan plan)
         (dial-adopted-host m loc reach*
                            handshake-timeout-ms #:redeem? redeem?
                            #:plan plan))]
    [(rendezvous-dial? plan)
     (define route (locator-relay-route loc))
     (if (and route (not redeem?))
       (if (host-loop-of m)
           (dial-shared-loop m (host-loop-of m) loc reach
                             #:redeem? #f #:plan plan)
           (dial-adopted-host m loc reach handshake-timeout-ms
                              #:redeem? #f #:plan plan))
       (let ([url-of (host-rendezvous-url-value m)])
         (unless (or route url-of)
           (raise-pancake 'connect ERR-INVALID-ARGUMENT
                          "relay dial: locator has no rendezvous-relay hint and the Host has no rendezvous mapping"))
         (let ([url (if route (relay-dial-url route designator) (url-of designator))])
           (establish-dialed-locator-session m transport designator (ws-transport url)
                                             #:handshake-timeout-ms handshake-timeout-ms))))]
    [(signaling-dial? plan)
     (raise-pancake 'connect ERR-INVALID-ARGUMENT
                    "signaling dial requires an explicit signaling byte-channel integration")]
    [(host-port-dial? plan)
     (if (host-loop-of m)
         (dial-shared-loop m (host-loop-of m) loc
                           reach #:redeem? redeem? #:plan plan)
         (dial-adopted-host m loc reach
                            handshake-timeout-ms #:redeem? redeem?
                            #:plan plan))]
    [else (raise-pancake 'connect ERR-INVALID-ARGUMENT "unknown dial plan")]))

(define (dial-exporter m loc
                       #:handshake-timeout-ms
                       [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (dial-parsed-locator m loc #:redeem? #t
                       #:handshake-timeout-ms handshake-timeout-ms))

;; ── The native loop route (ADR-0112) ─────────────────────────────────────────

;; The iroh reachability a resolved peer-id plan names, for a loop dial. A
;; CONFIGURED posture arises only on a redeem plan, so a bare loop dial
;; falls back to the redeem default; a shared loop host answers with its
;; own configured posture.
(define (loop-peer-reach plan m)
  (define reach-kind (peer-id-dial-reach-kind plan))
  (cond
    [(= reach-kind DIAL-REACH-DIRECT) IROH-REACH-DIRECT]
    [(= reach-kind DIAL-REACH-CONFIGURED)
     (if m (host-redeem-reachability-value m) IROH-REACH-REDEEM-DEFAULT)]
    [else (peer-id-dial-reach-value plan)]))

(define (adopt-iroh! lp reach m)
  ((iroh-ref 'iroh-adopt-loop!) lp ((iroh-ref 'make-iroh-config) reach)
   #:seed (and m (host-seed m))))

;; The loop route for a bare bounded dial: the public `connect` path for the
;; shapes the loop carries — native TCP host:port, iroh endpoint, and routed
;; relay provider dials — one loop per connection, with the session
;; owning its loop so `session-close!` tears everything down, exactly the
;; one-host-per-connect ownership the byte-fed dial has.
;; Dial on a host a native loop already owns: the shared-host sibling for
;; `connect` with `#:host` naming a loop-backed
;; server's host. The loop is that host's one drain and release authority,
;; so the dial stages on it — the session shares the host's identity and
;; live-session directory, and the loop's handshake budget bounds it. A
;; transport the loop cannot carry is refused, never silently dialed
;; byte-fed on a host the loop owns.
(define (dial-shared-loop m lp loc reachability
                          #:redeem? [redeem? #f] #:plan [resolved-plan #f])
  (define transport (locator-transport loc))
  (define designator (locator-designator loc))
  (define addrs (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES ""))
  (define-values (policy value)
    (if redeem?
        (values DIAL-POSTURE-REDEEM 0)
        (if reachability
        (values DIAL-POSTURE-EXPLICIT reachability)
        (values DIAL-POSTURE-EXPLICIT-NONE 0))))
  (define plan (or resolved-plan (plan-dial transport designator addrs policy value)))
  (cond
    [(host-port-dial? plan)
     (driver-loop-add-tcp! lp)
     (loop-connect-session lp loc)]
    [(peer-id-dial? plan)
     (adopt-iroh! lp (loop-peer-reach plan m) m)
     (loop-connect-session lp loc)]
    [(rendezvous-dial? plan)
     (define route (locator-relay-route loc))
     (unless route
       (raise-pancake 'connect ERR-INVALID-ARGUMENT
                      "native relay provider requires a rendezvous-relay locator hint"))
     (driver-loop-add-relay! lp route)
     (loop-connect-session lp loc)]
    [else
     (raise-pancake 'connect ERR-INVALID-ARGUMENT
                    "the native loop that owns this host carries no \"~a\" dial; open this connection from a byte-fed host instead"
                    transport)]))

;; Transfer a caller-owned Host before a native provider dial. The
;; transfer is the only ownership transition; after it succeeds the same Host
;; wrapper remains the session's authority and the loop owns its release.
(define (dial-adopted-host m loc reachability
                           handshake-timeout-ms #:redeem? [redeem? #f]
                           #:plan [resolved-plan #f])
  (define transport (locator-transport loc))
  (define designator (locator-designator loc))
  (define addrs (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES ""))
  (when (or (not handshake-timeout-ms) (not (positive? handshake-timeout-ms)))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "native TCP and iroh drivers require a positive handshake timeout"))
  (define-values (policy value)
    (if redeem?
        (values DIAL-POSTURE-REDEEM 0)
        (if reachability
        (values DIAL-POSTURE-EXPLICIT reachability)
        (values DIAL-POSTURE-EXPLICIT-NONE 0))))
  (define plan (or resolved-plan (plan-dial transport designator addrs policy value)))
  (define lp
    (open-driver-loop #:host m #:handshake-ms handshake-timeout-ms))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (driver-loop-abort! lp) (raise e))])
    (cond
      [(host-port-dial? plan) (driver-loop-add-tcp! lp)]
      [(peer-id-dial? plan)
       (adopt-iroh! lp (loop-peer-reach plan m) m)
       (void)]
      [(rendezvous-dial? plan)
       (define route (locator-relay-route loc))
       (unless route
         (raise-pancake 'connect ERR-INVALID-ARGUMENT
                        "native relay provider requires a rendezvous-relay locator hint"))
       (driver-loop-add-relay! lp route)]
      [else
       (driver-loop-abort! lp)
       (raise-pancake 'connect ERR-INVALID-ARGUMENT
                      "the supplied Host's driver has no native \"~a\" provider"
                      transport)])
    (driver-loop-start! lp)
    (loop-connect-session lp loc)))

;; Execute one DIAL action, post-lock — the drain parks it among the fires,
;; because the dial is a connect syscall plus a whole keyed handshake and
;; would otherwise hold the host lock across both, parking every thread that
;; shares the host behind one slow exporter. The executor takes the lock only
;; inside the brief host verbs it contains, and each completion report opens
;; its own locked drain window, so the withdraw legs the report queues
;; (deposits, settles, flushes) drain as that report's own effects. A failed
;; dial breaks every waiting redeem with the reason. The exporter connection
;; is kept pumped by a background serve so the withdraw's resolution — and
;; any later routed traffic — is read.
(define (run-dial! m ticket)
  ;; Ticket-only DIAL: clone the complete parsed locator, then dial. The
  ;; dynamic-wind after-thunk is the terminal guard: a break aimed at the
  ;; executing green thread cannot strand the already-popped ticket.
  (define c #f)
  (define reported? #f)
  (define failure "dial interrupted")
  (dynamic-wind
   void
   (lambda ()
     (with-handlers ([converts-to-broken?
                      (lambda (e) (set! failure (exn->message e)))])
       (define-values (rc locator-view)
         (pancake_host_pending_dial (host-ptr m) ticket))
       (check/host rc)
       (define loc (clone-locator-view locator-view))
       (set! c (dial-exporter m loc))
       (with-host-drain m
         (lambda ()
           ;; The report and local commit bit are one unbreakable transition:
           ;; after host-dialed succeeds this ticket no longer admits a failure
           ;; report, even if a later drain effect is interrupted.
           (parameterize-break
            #f
            (host-dialed! m ticket (session-ptr c))
            (set! reported? #t))
           (drain-host-actions! m)))
       (void)))
   (lambda ()
     ;; Cleanup and post-commit serve ownership must both survive a pending
     ;; break. The after-thunk runs exactly once, so a reported session gets
     ;; exactly one reader thread even when interruption lands after commit.
     (parameterize-break
      #f
      (if reported?
          (thread (lambda () (with-handlers ([converts-to-broken? void]) (session-serve c))))
          (begin
            ;; Roll back the opened session before failure is reported, matching
            ;; the transactional C Host contract.
            (when c
              (with-handlers ([(lambda (_e) #t) void]) (session-close! c)))
            (unless (unbox (host-released? m))
              (with-handlers
                  ([(lambda (_e) #t) void])
                (with-host-drain m
                  (lambda ()
                    (host-dial-failed! m ticket failure)
                    (drain-host-actions! m)))))))))))

;; Dial a partner from its `ocapn://` locator: parse once, call
;; `pancake_host_plan_dial`, and open the byte channel the plan names. There is
;; no other dial: a literal address is a `tcp` locator, built with `tcp-locator`.
;; The core owns transport dispatch and grammar. `reachability` (an
;; IROH-REACH-* posture) is required only when the locator's transport is
;; `iroh`; a `tcp` locator ignores it, so a plain TCP dial needs nothing but the
;; locator. An iroh locator with no posture fails closed rather than guessing one.
;; `#:host` shares one CapTP host identity and handoff router across several
;; sessions — the gifter side of a three-party handoff, where the same host
;; both serves recipients (via `listen`/`accept`) and dials the exporter it
;; re-gifts from. Omit it for a standalone session with a fresh identity.
;; `#:handshake-timeout-ms` bounds the keyed handshake at `HANDSHAKE-TIMEOUT-MS`
;; by default, so a partner that accepts the connection and then says nothing
;; costs this dial an ERR-TIMEOUT rather than the calling thread; pass #f (or 0)
;; to wait forever.
(define (connect uri [reachability #f] #:host [shared-host #f] #:codec [codec #f]
                 #:captp-version [captp-version #f] #:features [features #f]
                 #:handshake-timeout-ms [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (define loc (parse-locator uri))
  ;; Fail closed on conflicting Host-owned protocol options: a fresh host is
  ;; minted with them, and a shared host already carries them.
  (when (and shared-host codec (not (eq? codec (host-codec shared-host))))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "#:codec ~a conflicts with the shared host's ~a" codec (host-codec shared-host)))
  (when (and shared-host captp-version (not (eq? captp-version (host-captp-version shared-host))))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "#:captp-version ~a conflicts with the shared host's ~a"
                   captp-version (host-captp-version shared-host)))
  (when (and shared-host features
             (not (= (feature-mask features)
                     (feature-mask (host-features shared-host)))))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "#:features ~a conflicts with the shared host's ~a"
                   features (host-features shared-host)))
  (define m (or shared-host (make-fresh-host #:codec (or codec 'syrup)
                                              #:captp-version (or captp-version 'v1_0)
                                              #:features (or features 'full))))
  (define c (dial-parsed-locator m loc
                                 #:reachability reachability
                                 #:handshake-timeout-ms handshake-timeout-ms))
  ;; A host this connect had to mint has no other owner, so the session it
  ;; returns closes it; a caller-supplied one is the caller's to close.
  (unless shared-host (set-box! (session-owns-host? c) #t))
  c)
