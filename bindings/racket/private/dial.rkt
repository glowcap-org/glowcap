#lang racket/base
;; The dial executor (binding spine Pass 3c): one path that turns a parsed
;; locator into an open, handshaken `session`, shared by `connect` and
;; handoff-redeem alike.
;;
;; Every dial decision — the host:port grammar, the direct-addresses hint rule,
;; the iroh reachability posture, the scheme dispatch, and the typed errors —
;; is resolved once in the core by `pancake_host_plan_dial`, which hands back a
;; `PancakeDialPlan`. This module holds no dial business logic: it marshals the
;; posture, reads the plan, and performs the one thing the core cannot — the
;; byte-channel open (`tcp-connect`, or the iroh companion). Adding a transport
;; is a core change, not an edit here. Session owns mint/handshake
;; (`establish-dialed-locator-session` / `establish-accepted-session`); this
;; module owns plan + channel open + the public `connect` dialer.
;;
;; Lazy-require breaks the session ↔ dial cycle: dial lazy-requires session
;; for establish / serve / drain choreography; the public barrel
;; (`pancake.rkt`) requires dial directly.

(require racket/tcp
         racket/lazy-require
         racket/runtime-path
         "constants.rkt"
         "ffi-driver.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "vat.rkt"
         "locator.rkt"
         "async.rkt"
         "host.rkt"
         "action.rkt")

(lazy-require
 ["session.rkt"
  (establish-dialed-locator-session
   session-serve
   session-ptr
   with-host-drain)])

(provide iroh-dial-mod
         (struct-out resolved-dial)
         plan-dial
         dial-parsed-locator
         dial-exporter
         run-dial!
         connect)

;; ── The dial executor (a DIAL action's binding half) ─────────────────────────
;; The host asks for a dial with the exporter's full `ocapn://` locator URI and
;; its parsed pieces (transport, designator, direct-addresses hint) already on
;; the action, so the executor re-parses nothing; which netlayer answers — and
;; under which reachability posture — is the binding's decision, never the
;; ABI's. A `tcp` locator dials its host:port; an `iroh` locator with a
;; direct-address hint dials it relay-less (Direct), and a bare node id
;; resolves under the host's configured redeem posture (default Discovery;
;; `set-host-redeem-reachability!` lowers it), so one give shape covers an
;; offline direct dial and an internet dial-by-id alike. The iroh companion
;; loads lazily, only for an iroh give.
(define-runtime-path iroh-companion-path "../pancake-iroh.rkt")
(define (iroh-dial-mod) `(submod ,iroh-companion-path dial))

;; A resolved dial from `pancake_host_plan_dial`: what channel to open and how.
;; The (ptr,len) views are read into strings here, before the input buffers die.
(struct resolved-dial (shape host port addresses reach-kind reach-value))

(define (plan-dial transport designator addrs policy value)
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define hb (string->bytes/utf-8 addrs))
  (define plan (make-PancakeDialPlan 0 #f 0 0 #f 0 0 0))
  (check/host (pancake_host_plan_dial tb (bytes-length tb) db (bytes-length db)
                                      hb (bytes-length hb) policy value plan))
  (define (view ptr len)
    (if (and ptr (> len 0)) (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD) ""))
  (resolved-dial
   (PancakeDialPlan-shape plan)
   (view (PancakeDialPlan-host plan) (PancakeDialPlan-host-len plan))
   (PancakeDialPlan-port plan)
   (view (PancakeDialPlan-addresses plan) (PancakeDialPlan-addresses-len plan))
   (PancakeDialPlan-reach-kind plan)
   (PancakeDialPlan-reach-value plan)))

;; The one dial path for `connect` and handoff redeem alike: no dispatch, no
;; grammar, no posture — the core resolves all of that in `pancake_host_plan_dial`,
;; and this opens the byte channel it names.
(define (dial-parsed-locator m transport designator addrs
                             #:reachability [reach #f]
                             #:redeem? [redeem? #f])
  (define-values (policy value)
    (cond [redeem? (values DIAL-POSTURE-REDEEM 0)]
          [reach (values DIAL-POSTURE-EXPLICIT reach)]
          [else (values DIAL-POSTURE-EXPLICIT-NONE 0)]))
  (define plan (plan-dial transport designator addrs policy value))
  (cond
    [(= (resolved-dial-shape plan) DIAL-SHAPE-IROH)
     (define reach-kind (resolved-dial-reach-kind plan))
     (define reach*
       (cond [(= reach-kind DIAL-REACH-DIRECT) (dynamic-require iroh-companion-path 'IROH-REACH-DIRECT)]
             [(= reach-kind DIAL-REACH-CONFIGURED) (host-redeem-reachability-value m)]
             [else (resolved-dial-reach-value plan)]))
     ((dynamic-require (iroh-dial-mod) 'connect-iroh/node)
      designator (resolved-dial-addresses plan) reach* m)]
    [else
     (define-values (in out) (tcp-connect (resolved-dial-host plan) (resolved-dial-port plan)))
     (with-handlers ([(lambda (_) #t)
                      (lambda (e)
                        (with-handlers ([(lambda (_) #t) void])
                          (close-output-port out)
                          (close-input-port in))
                        (raise e))])
       (establish-dialed-locator-session m transport designator (port-transport in out)))]))

(define (dial-exporter m transport designator addrs)
  (dial-parsed-locator m transport designator addrs #:redeem? #t))

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
(define (run-dial! m ticket transport designator addrs)
  (with-handlers ([converts-to-broken?
                   (lambda (e)
                     (with-host-drain m
                       (lambda ()
                         (host-dial-failed! m ticket (exn->message e))
                         (drain-host-actions! m))))])
    (define c (dial-exporter m transport designator addrs))
    (with-host-drain m
      (lambda ()
        (host-dialed! m ticket (session-ptr c))
        (drain-host-actions! m)))
    (thread (lambda () (with-handlers ([converts-to-broken? void]) (session-serve c))))
    (void)))

;; Dial a partner from its `ocapn://` locator — the one dialer, dispatching on the
;; locator's transport: `iroh` dials the endpoint id with its `direct-addresses`
;; hints, `tcp` dials the `host:port` designator. There is no other dial: a
;; literal address is a `tcp` locator, built with `tcp-locator`. Parse once
;; through the core grammar, which picks the netlayer. `reachability` (an
;; IROH-REACH-* posture) governs the iroh branch and is required only when the
;; locator's transport is `iroh`; a `tcp` locator ignores it, so a plain TCP dial
;; needs nothing but the locator. An iroh locator with no posture fails closed
;; rather than guessing one.
;; `#:host` shares one CapTP host identity and gift registry across several
;; sessions — the gifter side of a three-party handoff, where the same host
;; both serves recipients (via `listen`/`accept`) and dials the exporter it
;; re-gifts from. Omit it for a standalone session with a fresh identity.
(define (connect uri [reachability #f] #:host [shared-host #f] #:codec [codec #f])
  (define loc (parse-locator uri))
  (define transport (locator-transport loc))
  ;; Fail closed on a conflicting codec: the codec is the host's, so a fresh
  ;; host is minted with `#:codec`, and a shared host already carries one.
  (when (and shared-host codec (not (eq? codec (host-codec shared-host))))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "#:codec ~a conflicts with the shared host's ~a" codec (host-codec shared-host)))
  (define addrs (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES ""))
  (define m (or shared-host (make-fresh-host #:codec (or codec 'syrup))))
  (dial-parsed-locator m transport (locator-designator loc) addrs
                       #:reachability reachability))
