#lang racket/base

;; captp.rkt — Goblins-API-compatible CapTP MVP backed by pancake-ffi.
;;
;; THE CLAIM THIS MODULE EXISTS TO PROVE: a Goblins app can be hosted
;; on pancake-ffi for its OCapN wire protocol, with `(require
;; pancake-goblins/captp)` substituting for `(require
;; goblins/ocapn/captp)` and everything else of the app's source
;; unchanged.
;;
;; SCOPE — MVP only. This intentionally implements a tiny slice of
;; upstream goblins/ocapn/captp.rkt's surface — enough to host a
;; single registered actor that responds to a single fetched
;; invocation. Specifically:
;;
;;   IN:   spawn-mycapn returning a `^mycapn` actor with:
;;           ($ mycapn 'register actor swissnum) — registers a local actor
;;           ($ mycapn 'get-registry) — returns the nonce-registry
;;         Inbound TCP connections from a partner doing
;;         op:bootstrap → op:fetch <swissnum> → op:deliver →
;;         (we route to actor) → op:resolve → partner
;;
;;   OUT:  Anything an outbound-dialing consumer would need:
;;           - ($ mycapn 'enliven sturdyref)
;;           - ($ mycapn 'connect-to-node location)
;;           - Promise pipelining (op:listen, vow chaining)
;;           - Three-vat handoff
;;           - Sealers / unsealers / wards / interested-in-sever
;;
;; The MVP is honest about what it doesn't cover. Building out the
;; full upstream surface is graduation-criterion work; the MVP
;; proves the substantive seam (a Goblins app hosting an actor on
;; pancake-backed wire) without claiming completeness.
;;
;; PUMP MODEL — one Racket green thread per accepted connection.
;; Polls pancake-endpoint-tcp-read-frame with a short timeout
;; (50 ms) so the pump yields back to other Racket green threads
;; between reads. On each iteration: feed any inbound frame into
;; pancake-ffi; step; drain pancake_peer_take_outbound to
;; pancake-endpoint-tcp-write-frame; poll typed Deliver events;
;; dispatch each Deliver via the vat to the registered actor;
;; send pancake_peer_send_resolve with the result. The vat-run
;; pattern provides synchronous invocation from the pump thread.
;;
;; Matrix #3 migration: the per-connection pump no longer uses
;; Racket-side framing (syrup-framing.rkt) or Racket socket I/O —
;; the endpoint surface from pancake-ffi owns both.

(provide spawn-mycapn)

(require racket/async-channel
         racket/match
         racket/contract
         goblins
         goblins/vat
         (submod goblins/core np-extern)            ; <-np-extern: thread-safe send into vat
         goblins/actor-lib/methods
         goblins/actor-lib/nonce-registry
         (only-in goblins/core live-refr?)          ; predicate for cap-passing
         "pancake-ffi.rkt")

;; ─── Public entry point ────────────────────────────────────────────

;; spawn-mycapn — mirrors upstream goblins/ocapn/captp.rkt's
;; (provide spawn-mycapn) entry. Returns an actor; the consumer
;; treats it identically to upstream's ^mycapn for the methods this
;; MVP supports (`register`, `get-registry`).
;;
;; netlayers — variadic; same shape as upstream's. The MVP supports
;; the pancake-tcp-netlayer this directory provides (gives raw bytes
;; rather than parsed Syrup values, which is what pancake-ffi wants).
;; Upstream's stock netlayers (^tcp-netlayer, ^fake-intarwebs) won't
;; work here — they call read-message with unmarshallers and return
;; parsed values; pancake-ffi needs raw bytes. The "pancake-flavored
;; netlayer" is the second swap line in the consumer:
;;
;;   - (require goblins/ocapn/captp           goblins-peer/racket/tcp-netlayer)
;;   + (require pancake-goblins/captp         pancake-goblins/pancake-tcp-netlayer)
(define (spawn-mycapn . netlayers)
  (define (^mycapn bcom)
    ;; Standard Goblins nonce-registry, reused unchanged from upstream
    ;; `goblins/actor-lib/nonce-registry`. We don't replace it; we
    ;; wrap it so the consumer's calls go through to upstream's
    ;; registry AND we side-effect the swissnum→export-id binding
    ;; that pancake-ffi's bootstrap-fetch consults.
    (match-define (cons inner-registry locator)
      (spawn-nonce-registry-locator-pair))

    ;; Map from swissnum (bytes) to (export-id . actor) so per-connection
    ;; pump threads can route inbound DeliverReceived events to the
    ;; right local actor. Shared across all connections (pancake-ffi
    ;; assigns export-ids per-peer, but we keep the swissnum→actor
    ;; map at the mycapn level so each new connection's peer can
    ;; register-bootstrap-cap with the same export-id slot).
    (define export-id->actor (make-hasheqv))
    (define swissnum->export-id (make-hash))
    (define next-export-id (box 1))

    (define (bind-swissnum-to-pancake! actor swissnum)
      (cond
        [(hash-ref swissnum->export-id swissnum #f)]
        [else
         (define eid (unbox next-export-id))
         (set-box! next-export-id (+ eid 1))
         (hash-set! swissnum->export-id swissnum eid)
         (hash-set! export-id->actor eid actor)
         eid]))

    ;; Spawn the long-lived dispatcher actor. Per-connection
    ;; pump threads forward each inbound Deliver to this
    ;; dispatcher via `<-np-extern` (the thread-safe entry); the
    ;; dispatcher does `(<- target args)` to invoke the actor +
    ;; uses `on` to register a handler that async-channel-puts
    ;; the actor's RESULT back to the pump's per-connection
    ;; result-ch.
    ;;
    ;; Without this dispatcher, the pump's reply path was
    ;; fire-and-forget — it sent back the INPUT args instead of
    ;; the actor's result, which only happens to be correct for
    ;; ^echo-shape actors (`(lambda args args)`). The dispatcher
    ;; enables hosting actors whose result differs from input.
    (define dispatcher (spawn ^dispatcher))

    ;; Set up each netlayer's connection-accept callback. The
    ;; pancake-flavored netlayer hands us (endpoint
    ;; remote-location) pairs; we spin up a per-connection
    ;; pancake peer + pump thread that takes ownership of the
    ;; endpoint.
    (for ([nl netlayers])
      ($ nl 'install-pancake-connection-handler
         (lambda (endpoint remote-location ops designator)
           (start-pancake-connection!
             endpoint remote-location ops designator
             export-id->actor
             swissnum->export-id
             dispatcher))))

    ;; Wrap the inner registry: every register call goes through to
    ;; the upstream nonce-registry (returning the upstream sturdyref
    ;; unchanged) AND side-effects the pancake-ffi binding when a
    ;; swissnum is supplied. The wrapper exposes the same method
    ;; surface (register, fetch) as upstream's nonce-registry, so
    ;; the consumer code is byte-identical to a Spritely-Goblins
    ;; host.
    (define (^pancake-registry-wrapper bcom)
      (methods
       [(register refr [swiss-num #f])
        ;; Forward to upstream nonce-registry — preserves upstream's
        ;; sturdyref-allocation + fetch semantics.
        (define sturdyref
          (if swiss-num
              ($ inner-registry 'register refr swiss-num)
              ($ inner-registry 'register refr)))
        ;; Side-effect: bind swissnum→export-id for pancake-ffi's
        ;; bootstrap-fetch table. Only when a swissnum was provided
        ;; (random-nonce registrations aren't bootstrap-fetched).
        (when swiss-num
          (bind-swissnum-to-pancake! refr swiss-num))
        sturdyref]
       [(fetch swiss-num) ($ inner-registry 'fetch swiss-num)]))
    (define wrapped-registry (spawn ^pancake-registry-wrapper))

    (methods
     [(get-registry) wrapped-registry]
     [(get-locator) locator]))

  (spawn ^mycapn))

;; ─── Per-connection pancake peer + pump ────────────────────────────

;; Read-timeout for the per-connection poll loop. Matches the value
;; in tcp-bridge.rkt — short enough for responsiveness, long
;; enough to amortize the syscall overhead.
(define POLL-READ-TIMEOUT-MS 50)

;; Long-lived dispatcher actor. Lives in the captp module's vat
;; (the vat that called spawn-mycapn). Per-connection pump
;; threads forward each inbound Deliver to this dispatcher via
;; `<-np-extern`; the dispatcher captures the actor's actual
;; result via `<-` + `on`, then async-channel-puts the tagged
;; result onto the pump's per-connection result-ch.
;;
;; Method:
;;   ('invoke result-ch answer-info target racket-args)
;; Posts to result-ch when done:
;;   (list answer-info (list 'ok <result>))      on Fulfill
;;   (list answer-info (list 'err <exn-message>)) on Break
(define (^dispatcher _bcom)
  (methods
   [(invoke result-ch answer-info target racket-args)
    (with-handlers ([exn? (lambda (e)
                            (async-channel-put result-ch
                              (list answer-info (list 'err (exn-message e)))))])
      (define vow (apply <- target racket-args))
      (on vow
          (lambda (r)
            (async-channel-put result-ch
              (list answer-info (list 'ok r))))
          #:catch
          (lambda (err)
            (async-channel-put result-ch
              (list answer-info (list 'err err))))))]))

;; Called by the netlayer when a new TCP connection arrives. Spins
;; up the pancake-ffi peer + a single Racket green-thread pump.
;; Takes ownership of `endpoint`; closes it when the pump exits.
(define (start-pancake-connection! endpoint remote-location
                                   ops designator
                                   export-id->actor
                                   swissnum->export-id
                                   dispatcher)
  ;; Transport vtable (cleartext TCP / TCP+TLS / iroh). The netlayer
  ;; hands us its `transport-ops` bundle so this pump is transport-
  ;; agnostic — the OCapN-seam logic below is identical regardless of
  ;; which netlayer accepted the connection.
  (define tx-read-frame (transport-ops-read-frame ops))
  (define tx-write-frame (transport-ops-write-frame ops))
  (define tx-close (transport-ops-conn-close ops))
  (define tx-set-read-timeout (transport-ops-set-read-timeout ops))
  ;; Fresh Ed25519 keypair per connection; the typed pancake-peer-new
  ;; pins V1_0 + goblins_v1_0 (the wire shape Spritely speaks) and
  ;; takes ownership of the keypair — freed as part of pancake-peer-free.
  (define kp (pancake-keypair-new))
  (define peer (pancake-peer-new kp PANCAKE_CODEC_SYRUP))

  ;; Register every swissnum→export-id we know about so pancake-ffi
  ;; handles bootstrap-fetch transparently. The partner's op:bootstrap
  ;; → op:fetch <swissnum> never surfaces as a DeliverReceived event
  ;; — pancake-ffi looks up the swissnum in its bootstrap-caps table
  ;; and responds with the export-id directly. THEN when the partner
  ;; invokes the fetched cap via op:deliver, that's when DeliverReceived
  ;; fires and the pump dispatches to the actor.
  (for ([(swissnum eid) (in-hash swissnum->export-id)])
    (pancake-peer-register-bootstrap-cap peer swissnum eid))

  ;; Set the endpoint's read timeout so the pump yields between
  ;; reads (same single-thread cooperative-scheduling pattern as
  ;; tcp-bridge.rkt).
  (tx-set-read-timeout endpoint POLL-READ-TIMEOUT-MS)

  ;; Per-connection result channel. The dispatcher (vat-resident)
  ;; async-channel-puts here when an actor invocation resolves;
  ;; the pump drains it each tick + sends the appropriate
  ;; op:resolve / op:deliver-to-resolver-callback reply.
  (define result-ch (make-async-channel))

  ;; Per-connection refr→eid cache for cap-passing. When an
  ;; actor's result contains a Goblins refr (live-refr?), the
  ;; pump allocates a fresh export-id for it + tells pancake-ffi
  ;; via pancake-peer-register-export. Subsequent invocations
  ;; reuse the cached eid so the partner sees the same import-id
  ;; each time. Per-connection because eids are scoped to a
  ;; pancake-ffi peer; different connections allocate
  ;; independently.
  (define refr-cache (make-hasheq))
  (define conn-next-eid (box (max-eid-in-hash export-id->actor)))

  (define (allocate-conn-eid!)
    (define eid (unbox conn-next-eid))
    (set-box! conn-next-eid (+ eid 1))
    eid)

  (define (register-refr! refr)
    (cond
      [(hash-ref refr-cache refr #f) => values]
      [else
       (define eid (allocate-conn-eid!))
       (hash-set! refr-cache refr eid)
       (hash-set! export-id->actor eid refr)
       (pancake-peer-register-export peer eid)
       eid]))

  ;; Pump: single green thread. Reads inbound (with timeout),
  ;; feeds, steps, drains outbound, dispatches events, drains
  ;; ready actor results.
  (define pump
    (thread
      (lambda ()
        ;; The peer's stored keypair signs the outbound StartSession
        ;; (A2/A3 collapsed signature — transport + designator on
        ;; the call; the keypair is per-peer, not per-call).
        (pancake-peer-send-start-session
          peer (transport-ops-transport-name ops) designator)
        (let loop ()
          ;; 1. Inbound (poll-style).
          (define frame (tx-read-frame endpoint))
          (case frame
            [(would-block) (void)]
            [(closed eof)
             (tx-close endpoint)
             (pancake-peer-free peer)
             (kill-thread (current-thread))]
            [(malformed)
             (eprintf "[pancake-captp] malformed inbound; closing connection~n")
             (tx-close endpoint)
             (pancake-peer-free peer)
             (kill-thread (current-thread))]
            [else
             (cond
               ;; Zero-copy inbound: decode + dispatch directly over the
               ;; freshly-read bytevector (no owned-Frame copy). The
               ;; bytes are borrowed only for this call; the next
               ;; pancake-peer-step drains the resulting outbound.
               [(bytes? frame) (pancake-peer-feed-inbound peer frame)]
               [else
                (eprintf "[pancake-captp] unexpected read_frame ~v~n" frame)
                (tx-close endpoint)
                (pancake-peer-free peer)
                (kill-thread (current-thread))])])
          ;; 2. Drain ready actor results (results that the
          ;; dispatcher has finished + queued on result-ch).
          ;; This runs BEFORE step so any new outbound from
          ;; pancake_peer_send_resolve/_deliver gets a chance to
          ;; drain in the same tick.
          (let drain-results ()
            (define r (async-channel-try-get result-ch))
            (when r
              (apply send-actor-reply peer register-refr! r)
              (drain-results)))
          ;; 3. Step + drain outbound.
          (pancake-peer-step peer)
          (let drain-out ()
            (define out (pancake-peer-take-outbound peer))
            (when out
              (tx-write-frame endpoint out)
              (drain-out)))
          ;; 4. Drain typed Deliver events (forwards to dispatcher).
          (drain-typed-events! peer export-id->actor dispatcher result-ch)
          ;; 5. Loop or close.
          (cond
            [(= (pancake-peer-session-state peer) PANCAKE_SESSION_CLOSED)
             (tx-close endpoint)
             (pancake-peer-free peer)]
            [else
             ;; Yield to other green threads (the Goblins vat,
             ;; other connections, etc.).
             (sleep 0.001)
             (loop)])))))

  ;; Return immediately; pump runs until socket closes.
  (void))

;; Drain pancake-ffi typed events. For each DeliverReceived:
;; 1. Identify the target actor by export-id.
;; 2. Forward to the vat-resident dispatcher via `<-np-extern`.
;;    The dispatcher invokes the actor + captures the result via
;;    `<-` + `on`, then async-channel-puts to result-ch.
;; 3. The pump's loop drains result-ch + sends the op:resolve
;;    (or op:deliver-to-resolver-callback) reply.
;;
;; Actor results are now real (per the dispatcher pattern) — the
;; reply payload is the actor's ACTUAL return value, not the
;; input echo. Supports actors whose return value differs from
;; input + actors whose result is a vow that takes time to
;; settle. Break (failed) outcomes route as op:resolve(Break,
;; <error>) or the V1.0 callback equivalent.
(define (drain-typed-events! peer export-id->actor dispatcher result-ch)
  (let drain ()
    (define ev (pancake-peer-poll-event-deliver peer))
    (when ev
      (handle-deliver! peer
                       (list-ref ev 0)   ; target
                       (list-ref ev 1)   ; args
                       (list-ref ev 2)   ; answer-id (or #f)
                       (list-ref ev 3)   ; resolve-me-desc (or #f)
                       export-id->actor
                       dispatcher
                       result-ch)
      (drain)))
  ;; Drain other typed event kinds so they don't accumulate; MVP
  ;; doesn't route them further (Resolve/Abort happen outside the
  ;; receive-side; SessionEstablished is informational).
  (let drain () (when (pancake-peer-poll-event-resolve peer) (drain)))
  (pancake-peer-poll-event-abort peer)
  (pancake-peer-poll-event-session-established peer)
  ;; Anything still pending is of a kind we don't have a typed
  ;; handler for; drop it via pancake-peer-consume-event (the
  ;; explicit drop-this verb the A4 redesign added — calling
  ;; pancake-peer-peek-event-kind here would never consume).
  (let drain () (when (pancake-peer-consume-event peer) (drain))))

(define (handle-deliver! peer target args answer-id resolve-me-desc
                         export-id->actor dispatcher result-ch)
  ;; target is a pcakeref. For a Near(export_id) target, look up the
  ;; actor; for anything else, this MVP doesn't handle it (it'd be a
  ;; partner-side ref we don't track).
  (cond
    [(= (pcakeref-kind target) PANCAKE_REF_NEAR)
     (define export-id (pcakeref-payload target))
     (define actor (hash-ref export-id->actor export-id #f))
     (cond
       [actor (forward-to-dispatcher!
                actor args answer-id resolve-me-desc
                dispatcher result-ch)]
       [else
        ;; export-id 0 is the bootstrap pseudo-position; pancake-ffi
        ;; recognizes + auto-replies to bootstrap-fetch before
        ;; surfacing this event, so a "no actor for 0" sighting here
        ;; is the benign echo of an auto-handled fetch. Other
        ;; missing export-ids are real dispatch failures.
        (unless (zero? export-id)
          (eprintf "[pancake-captp] no actor for export-id ~a (registered: ~v)~n"
                   export-id (hash-keys export-id->actor)))])]
    [else
     (eprintf "[pancake-captp] Deliver target kind=~a not handled in MVP~n"
              (pcakeref-kind target))]))

;; Cross the pump-thread → vat boundary via <-np-extern. The
;; dispatcher (vat-resident) invokes the actor + captures the
;; result via on; the result lands on result-ch for the pump to
;; drain in a later iteration.
(define (forward-to-dispatcher! actor args answer-id resolve-me-desc
                                dispatcher result-ch)
  (define racket-args
    (for/list ([a (in-list args)])
      (pcakearg->racket a)))
  (define answer-info (list answer-id resolve-me-desc))
  (with-handlers ([exn? (lambda (e)
                          (eprintf "[pancake-captp] dispatcher forward failed: ~a~n"
                                   (exn-message e)))])
    (<-np-extern dispatcher 'invoke result-ch answer-info actor racket-args)))

;; Called from the pump's result-ch drain. Sends the reply
;; (op:resolve OR op:deliver-to-resolver-callback) carrying the
;; actor's actual result. Dispatches on:
;;   answer-info → which reply route the partner asked for
;;   tagged-result → Fulfill (Ok) vs Break (Err)
(define (send-actor-reply peer register-refr! answer-info tagged-result)
  (match-define (list answer-id resolve-me-desc) answer-info)
  (define resolution
    (match tagged-result
      [(list 'ok r) (res-fulfill (racket->pcakearg r register-refr!))]
      [(list 'err err)
       ;; Goblins exception → Break with the message as the
       ;; error reason. Future: project Goblins-specific error
       ;; structs into typed pancake Error variants.
       (define msg
         (cond [(string? err) err]
               [(exn? err) (exn-message err)]
               [else (format "~v" err)]))
       (res-break msg)]))
  (cond
    [answer-id
     (pancake-peer-send-resolve peer answer-id resolution)]
    [resolve-me-desc
     ;; The V1.0 resolver-callback wire shape is op:deliver to
     ;; the resolver Far ref with args = [Symbol("fulfill"|"break"),
     ;; <payload>]. Matches
     ;; `pancake_runtime::v1_0::resolver_callback_message`'s
     ;; outbound shape; matches the partner's
     ;; `session_translate_inbound_view` recognition.
     (match tagged-result
       [(list 'ok r)
        (pancake-peer-send-deliver
          peer resolve-me-desc
          (list (arg-symbol "fulfill") (racket->pcakearg r register-refr!)))]
       [(list 'err err)
        (define msg
          (cond [(string? err) err]
                [(exn? err) (exn-message err)]
                [else (format "~v" err)]))
        (pancake-peer-send-deliver
          peer resolve-me-desc
          (list (arg-symbol "break") (arg-string msg)))])]
    [else
     ;; Neither reply route — partner sent a fire-and-forget
     ;; deliver. The actor was invoked; result is discarded.
     (void)]))

;; ─── Argument translation ──────────────────────────────────────────

;; pcakearg → Racket native value. Symbol becomes a Racket symbol;
;; everything else uses the payload as-is.
(define (pcakearg->racket pa)
  (define kind (pcakearg-kind pa))
  (define payload (pcakearg-payload pa))
  (cond
    [(= kind PANCAKE_ARG_SYMBOL) (string->symbol payload)]
    [(= kind PANCAKE_ARG_BYTES) payload]
    [(= kind PANCAKE_ARG_STRING) payload]
    [(= kind PANCAKE_ARG_INTEGER) payload]
    [(= kind PANCAKE_ARG_BOOL) payload]
    [(= kind PANCAKE_ARG_VOID) (void)]
    [(= kind PANCAKE_ARG_LIST)
     ;; C1 — payload is a Racket list of pcakearg; recurse.
     (map pcakearg->racket payload)]
    [else
     (eprintf "[pancake-captp] unsupported arg kind ~a in MVP~n" kind)
     #f]))

;; Racket native → pcakearg.
;;
;; `register-refr!` is a per-connection thunk: given a Goblins
;; refr, returns its allocated pancake export-id (allocates if
;; needed + tells pancake-ffi via pancake-peer-register-export).
;; Required for cap-passing: when an actor's result contains a
;; cap, the cap needs an export-id in the partner's import table
;; so subsequent op:deliver calls dispatch correctly.
(define (racket->pcakearg v register-refr!)
  (cond
    [(live-refr? v)
     (arg-reference (ref-near (register-refr! v)))]
    [(symbol? v) (arg-symbol (symbol->string v))]
    [(string? v) (arg-string v)]
    [(bytes? v) (arg-bytes v)]
    [(exact-integer? v) (arg-integer v)]
    [(boolean? v) (arg-bool v)]
    [(void? v) (arg-void)]
    [(list? v)
     ;; C1 typed List variant — wrap the elements recursively;
     ;; nested lists work the same way (the FFI's projection walks
     ;; the tree). Empty lists encode as arg-list with no items
     ;; rather than collapsing to arg-void, so a `()` and a
     ;; `(void)` round-trip distinctly.
     (arg-list (map (lambda (x) (racket->pcakearg x register-refr!)) v))]
    [else
     (eprintf "[pancake-captp] unsupported result type ~v in MVP; coerced to bytes~n" v)
     (arg-bytes (string->bytes/utf-8 (format "~v" v)))]))

;; Helper: max key in a hash, or 0 if empty. Used to seed the
;; per-connection eid counter beyond the bootstrap eids already
;; in export-id->actor.
(define (max-eid-in-hash h)
  (define keys (hash-keys h))
  (if (null? keys) 1 (+ 1 (apply max keys))))
