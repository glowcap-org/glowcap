#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require net/base64
         (only-in ffi/vector list->s64vector)
         (only-in ffi/unsafe ctype-sizeof)
         racket/random
         racket/runtime-path
         "../../glowcap.rkt"
         "../../glowcap-tcp.rkt"
         "../../glowcap-inproc.rkt"
         "../../glowcap-onion.rkt"
         "../../glowcap-iroh.rkt"
         (combine-in "../../private/session.rkt"
                     "../../private/session/state.rkt"
                     "../../private/session/establish.rkt"
                     "../../private/session/close.rkt")
         (combine-in "../../private/host.rkt" "../../private/host/state.rkt")
         (only-in "../../private/iroh.rkt" iroh-endpoint-record-failure!)
         "../../private/locator.rkt"
         "../../private/async.rkt"
         "../../private/byte-channel.rkt"
         (only-in "../../private/finalizer-diagnostics.rkt"
                  record-runtime-failure! run-ffi-finalizer!)
         (only-in "../../private/ws-transport.rkt" ws-transport)
         (only-in "../../relay.rkt" relay-pump exn:fail:relay?
                  exn:fail:relay-primary exn:fail:relay-secondary)
         "../../private/pump.rkt"
         "../../private/action.rkt"
         (only-in "../../private/dial.rkt" retain-host-cleanup-failure!)
         "../../private/promise.rkt"
         "../../private/gc.rkt"
         "../../private/vat.rkt"
         "../../private/ffi-host.rkt"
         "../../private/ffi-ocapn.rkt"
         "../../private/ffi-shared.rkt"
         "../../private/errors.rkt"
         "../../private/constants.rkt"
         "../../private/abi-value.rkt"
         (only-in "../../private/loop.rkt"
                  open-driver-loop driver-loop-start! driver-loop-abort!
                  loop-background-failed!
                  driver-loop-has-transport?
                  loop-listen! loop-listener-ready! loop-listener-locator
                  loop-listener-close!)
         "../../private/ffi-parent.rkt"
         (only-in "../../private/value.rkt" make-ref/internal)
         "support.rkt"
         racket/tcp)

;; ── Goblins for Racket: a counter actor, near-called and eventual-sent ────────
;; A Goblins-faithful actor: a constructor `(^counter bcom n)` the vat calls once
;; at spawn, returning a behavior built with `methods` that dispatches on a
;; leading method symbol. `add` becomes a fresh behavior over the new total via
;; `bcom`; `get` reports the current total. We spawn it in a vat, near-call it
;; with `$`, then eventual-send with `<-` and observe the vow with `on`.
(define demo-vat (make-vat))
(with-vat demo-vat
  ;; Near-call: `$` runs the behavior synchronously.
  (define counter (spawn ^counter 10))
  (expect (= 10 ($ counter 'get)) "actor: spawned counter starts at 10")
  (expect (= 15 ($ counter 'add 5)) "actor: ($ counter 'add 5) returns 15")
  (expect (= 15 ($ counter 'get)) "actor: bcom updated the count to 15")

  ;; Eventual-send: `<-` queues a turn and returns a vow; `on` observes it; the
  ;; turn (and the listener) run when we `drive` the vat.
  (define observed (box #f))
  (define add-vow (<- counter 'add 100))
  (on add-vow (lambda (total) (set-box! observed total)))
  (drive demo-vat)
  (expect (= 115 (unbox observed)) "actor: <- counter 'add 100 fulfilled the vow with 115"))

(printf "racket zig-smoke OK: Goblins-idiom actor, spawn, $, <-, on, bcom\n")

;; ── The local export table: bind-export! + vat-resolve-target ─────────────────
;; Hosting a behavior for a partner is the session's job (`session-spawn` /
;; `session-publish`). The vat still records which export id names which local
;; actor so a near reference resolves in-process (`vat-resolve-target`) instead
;; of going out on the wire to its own export. This is the same self-routing the
;; sibling bindings perform through their hosted tables.
(define lv (make-vat))
(define lv-counter (with-vat lv (spawn ^counter 10)))
(bind-export! lv lv-counter 7)
(expect (equal? (vat-resolve-target lv (make-ref/internal 7)) lv-counter)
        "local export: vat-resolve-target maps a bound Host ref to its actor")
(expect (equal? (vat-resolve-target lv (make-ref/internal 99)) (make-ref/internal 99))
        "local export: an unbound Host ref comes back unchanged")
(with-vat lv
  (expect (= 15 ($ lv-counter 'add 5)) "local export: the bound actor still near-calls"))

(printf "racket zig-smoke OK: bind-export! + vat-resolve-target self-route a Host ref\n")

;; ── The local|far seam: `<-` and `on` across a live session ────────────────
;; A host publishes a counter; the client reaches it through the vat verbs:
;; `(<- svc 'add 5)` through the session's vat is the same
;; location-transparent eventual-send a local actor gets, and `on` observes the
;; far vow. `session-await` pumps the wire until the partner's resolution fires it.
(define fs-server (listen "127.0.0.1" 0))
(define fs-ready (make-semaphore 0))
(define fs-ch (make-channel))
(define fs-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put fs-ch e))])
       (define hsession (accept fs-server))
       (session-publish hsession "counter" ^counter 10)
       (semaphore-post fs-ready)
       (session-serve hsession)
       (channel-put fs-ch 'served)))))
(define fs-session (open-test-session (tcp-locator "127.0.0.1" (server-port fs-server))))
(semaphore-wait fs-ready)
(define fs-svc (session-fetch fs-session "counter"))
(define fs-observed (box #f))
(define fs-vow (with-vat (session-vat fs-session) (<- fs-svc 'add 5)))
(with-vat (session-vat fs-session) (on fs-vow (lambda (total) (set-box! fs-observed total))))
(expect (= 15 (session-await fs-session fs-vow)) "far: (<- svc 'add 5) settled over the wire with 15")
(expect (= 15 (unbox fs-observed)) "far: the on listener observed the same settlement")
(session-close! fs-session)
(define fs-host-result (channel-get fs-ch))
(when (exn? fs-host-result) (raise fs-host-result))
(expect (eq? 'served fs-host-result) "far: host served to a clean close")
(server-close! fs-server)

(printf "racket zig-smoke OK: far-send round-trip across the local|far seam\n")

;; ── Disconnect: break-far-vows! settles a pending far vow as broken ───────────
;; A far vow waits on a resolve that rides the wire; if the connection drops it
;; can never arrive, so `break-far-vows!` settles the vow broken and the
;; `#:catch` handler runs instead of the awaiter waiting forever.
(define dc-server (listen "127.0.0.1" 0))
(define dc-ready (make-semaphore 0))
(define dc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept dc-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(greet who) "hi"])))
       (semaphore-post dc-ready)
       (session-serve hsession)))))
(define dc-session
  (open-test-session (tcp-locator "127.0.0.1" (server-port dc-server))
                     #:connector (tcp-connector)))
(semaphore-wait dc-ready)
(define dc-svc (session-fetch dc-session "svc"))
(define dc-broken (box #f))
;; The send is queued but never pumped to settlement, so the vow is pending
;; when the break fires.
(define dc-vow (with-vat (session-vat dc-session) (<- dc-svc 'greet "x")))
(with-vat (session-vat dc-session) (on dc-vow #f #:catch (lambda (msg) (set-box! dc-broken msg))))
(break-far-vows! (session-vat dc-session) "connection closed")
(expect (equal? "connection closed" (unbox dc-broken))
        "disconnect: break-far-vows! fired the far vow's #:catch handler")
(session-close! dc-session)
(void (sync/timeout 2 (thread-dead-evt dc-host)))
(server-close! dc-server)

(printf "racket zig-smoke OK: break-far-vows! settles a pending far vow on disconnect\n")

;; ── Cross-thread send: session-flush! puts another thread's bytes on the wire ────
;; A `<-` only enqueues; the bytes leave when something pumps. Work queued by a
;; green thread that is NOT the connection's pumping thread (a server pushing
;; a broadcast to a subscriber parked reading) must call `session-flush!` to put
;; the bytes on the wire. The client's inbox capability travels to the
;; server as an argument; a separate server thread tells it and flushes.
(define xf-server (listen "127.0.0.1" 0))
(define xf-ready (make-semaphore 0))
(define xf-session-box (box #f))
(define xf-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept xf-server))
       (set-box! xf-session-box hsession)
       (session-publish hsession "registry"
                     (lambda (bcom)
                       (methods
                        [(register cap)
                         ;; Hand the far inbox to a DIFFERENT green thread, which
                         ;; tells it and flushes (the cross-thread send seam).
                         (thread
                          (lambda ()
                            (define c (unbox xf-session-box))
                            (session-tell c cap 'note "broadcast")
                            (session-flush! c)))
                         "registered"])))
       (semaphore-post xf-ready)
       (session-serve hsession)))))
(define xf-session (open-test-session (tcp-locator "127.0.0.1" (server-port xf-server))))
(semaphore-wait xf-ready)
(define xf-notes (box '()))
(define xf-inbox
  (session-spawn xf-session
              (lambda (bcom)
                (methods [(note text) (set-box! xf-notes (cons text (unbox xf-notes)))]))))
(define xf-registry (session-fetch xf-session "registry"))
(expect (equal? "registered" (session-send xf-session xf-registry 'register xf-inbox))
        "cross-thread: the inbox capability registered")
;; Pump until the broadcast lands (the far tell arrives as a wire deliver into
;; our inbox actor).
(let loop ([i 0])
  (when (and (null? (unbox xf-notes)) (< i 200))
    (with-handlers ([exn:fail:glowcap? void])
      (session-send xf-session xf-registry 'register xf-inbox))
    (loop (add1 i))))
(expect (member "broadcast" (unbox xf-notes))
        "cross-thread: session-flush! put the other thread's tell on the wire")
(session-close! xf-session)
(void (sync/timeout 2 (thread-dead-evt xf-host)))
(server-close! xf-server)

(printf "racket zig-smoke OK: a cross-thread tell reaches the wire through session-flush!\n")

;; ── Concurrent pump: a send waits under another thread's session-serve ────────
;; The rooms client's `room-say` sends from the application thread while a
;; background `session-serve` keeps the same session pumped. One thread reads a
;; connection at a time (the pump's reader gate); a send arriving while the
;; serve thread holds the gate parks on the host's progress event and re-checks
;; its vow after every feed, so the answer, or the far side's refusal, lands on
;; the sending thread through the serve thread's reads.
(define sp-server (listen "127.0.0.1" 0))
(define sp-ready (make-semaphore 0))
(define sp-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept sp-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(echo text) text]
                        [(refuse) (error "observers cannot post")])))
       (semaphore-post sp-ready)
       (session-serve hsession)))))
(define sp-session (open-test-session (tcp-locator "127.0.0.1" (server-port sp-server))))
(semaphore-wait sp-ready)
(define sp-svc (session-fetch sp-session "svc"))
(define sp-serve
  (thread (lambda ()
            (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
              (session-serve sp-session)))))
;; THE PIN: send only once the serve thread holds the reader gate, so the send
;; cannot claim the gate itself and read its own answer.
(define (sp-wait-for-serve-gate!)
  (let loop ([i 0])
    (unless (eq? sp-serve (unbox (async-connection-reader (session-async sp-session))))
      (expect (< i 200) "concurrent pump: the serve thread never claimed the reader gate")
      (sleep 0.01)
      (loop (add1 i)))))
(sp-wait-for-serve-gate!)
(expect (equal? "line" (session-send sp-session sp-svc 'echo "line"))
        "concurrent pump: the application thread's send settled through the serve thread's reads")
(sp-wait-for-serve-gate!)
(define sp-refusal
  (with-handlers ([exn:fail:glowcap? values])
    (session-send sp-session sp-svc 'refuse)
    'no-error))
(expect (and (exn:fail:glowcap? sp-refusal)
             (equal? ERR-BROKEN (exn:fail:glowcap-code sp-refusal))
             (regexp-match? #rx"observers cannot post" (exn-message sp-refusal)))
        "concurrent pump: the far refusal raised on the sending thread with the wire reason")
(session-close! sp-session)
(void (sync/timeout 2 (thread-dead-evt sp-serve)))
(void (sync/timeout 2 (thread-dead-evt sp-host)))
(server-close! sp-server)

(printf "racket zig-smoke OK: a send from the application thread settled under another thread's session-serve\n")

;; ── Hosting: high-level listen/accept against connect ─────────────────────────
;; A host thread listens on an ephemeral port, accepts one partner on the
;; high-level surface, publishes `svc`, and serves. The main thread `connect`s,
;; fetches `svc`, and calls it. Both ends run a keyed op:start-session handshake on both
;; ends, no peer or vat wired by hand.
(define hl-server (listen "127.0.0.1" 0))
(define hl-ready (make-semaphore 0))
(define hl-ch (make-channel))
(define hl-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put hl-ch e))])
       (define hsession (accept hl-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(greet who) (string-append "hello " who)])))
       (semaphore-post hl-ready)
       (session-serve hsession)
       (channel-put hl-ch 'served)))))

;; `accept` blocks until someone dials, so connect first, then wait for the
;; publish before fetching.
(define hl-session (open-test-session (tcp-locator "127.0.0.1" (server-port hl-server))))
(semaphore-wait hl-ready)
(expect (equal? (partner-identity-locator-record (session-partner-identity hl-session))
                (encode-peer-locator
                 (locator TRANSPORT-TCP
                          (tcp-address-designator "127.0.0.1" (server-port hl-server))
                          (hash "glowcap/features"
                                "pipelining,handoff,wire_delta,sturdyref,untag")
                          'map)))
        "listen/accept: the host advertised the listener's complete locator record")
(define hl-svc (session-fetch hl-session "svc"))
(expect (equal? "hello glowcap" (session-send hl-session hl-svc 'greet "glowcap"))
        "listen/accept: high-level call round-tripped")
(session-close! hl-session)
(define hl-host-result (channel-get hl-ch))
(when (exn? hl-host-result) (raise hl-host-result))
(expect (eq? 'served hl-host-result) "listen/accept: host served to a clean close")
(server-close! hl-server)

(printf "racket zig-smoke OK: high-level listen/accept hosted a keyed session\n")

;; ── The live timeline producer ────────────────────────────────────────────────
;; The veneer stamps and forwards the FFI tap's facts, one flat record per
;; fact: session-opened with the codec the handshake negotiated,
;; the same verb outbound at the client and inbound at the server, and
;; session-closed. Endpoint labeling belongs to the consumer, so the records
;; carry only the session and direction.
(define trace-events (box '()))
(define trace-callback-failure
  (exn:fail "trace observer failed" (current-continuation-marks)))
(define trace-uninstall
  (enable-trace! (lambda (ev)
                   (set-box! trace-events (cons ev (unbox trace-events)))
                   (raise trace-callback-failure))
                 #:self-label "smoke"))
;; The FFI host retains a C function pointer, so the binding must retain the
;; actual callback object, not only the Racket procedure it was made from.
(collect-garbage)
(collect-garbage)
(define tr-server (listen "127.0.0.1" 0))
(define tr-ready (make-semaphore 0))
(define tr-serve
  (thread
   (lambda ()
     (define hsession (accept tr-server))
     (host-publish (session-host hsession) "tracer"
                            (lambda (method . args) "hello trace"))
     (semaphore-post tr-ready)
     (session-serve hsession))))
(define tr-session (open-test-session (tcp-locator "127.0.0.1" (server-port tr-server))))
(semaphore-wait tr-ready)
(define tr-cap (session-fetch tr-session "tracer"))
(expect (equal? "hello trace" (session-send tr-session tr-cap 'trace-me))
        "trace: the traced call still answers")
(define trace-failures (host-take-failures! (session-host tr-session)))
(expect (for/or ([failure (in-list trace-failures)])
          (and (equal? (failure-event-operation failure) "trace.sink")
               (positive? (failure-event-scope-id failure))
               (equal? (failure-event-primary-message failure)
                       "trace observer failed")))
        "trace: callback failure enters the Host diagnostic seam")
;; The annotation channel: the application states which partner a
;; session carries, named for the same session row the tap names.
(session-annotate! tr-session #:label "greeter-server")
(session-close! tr-session)
(server-close! tr-server)
(trace-uninstall)
(let* ([events (reverse (unbox trace-events))]
       [kinds (map (lambda (ev) (hash-ref ev 'kind)) events)]
       [msg? (lambda (ev) (equal? (hash-ref ev 'kind) "ocapn.message-decoded"))]
       [opened (filter (lambda (ev) (equal? (hash-ref ev 'kind) "ocapn.session-opened")) events)])
  (expect (>= (length opened) 2) "trace: both hosts' opens reached the one sink")
  (expect (andmap (lambda (ev) (and (equal? (hash-ref ev 'codec) "syrup")
                                    (equal? (hash-ref ev 'a_label #f) "smoke")))
                  opened)
          "trace: opens carry the codec and the application's display label")
  ;; And what this producer RUNS, because this schema is not glowcap's alone: a
  ;; consumer must not read an implementation off the fact that a record
  ;; arrived, so a glowcap host says so in words.
  (expect (andmap (lambda (ev) (equal? (hash-ref ev 'a_profile #f) "glowcap")) opened)
          "trace: an open states the implementation this producer runs")
  ;; Identity and label are two facts. `a` is the host's own key designator,
  ;; the name a partner knows it by, and so the only name two producers can
  ;; agree on. The label never stands in for it.
  (expect (andmap (lambda (ev) (regexp-match? #px"^[0-9a-f]{64}$" (hash-ref ev 'a "")))
                  opened)
          "trace: an open's `a` endpoint is the reporting host's key designator")
  ;; The OCapN Session ID is what lets a consumer merging two producers' feeds
  ;; tell one session watched twice from two unrelated ones: both peers of a
  ;; session derive it to the same value.
  (expect (let ([ids (map (lambda (ev) (hash-ref ev 'session_id #f)) opened)])
            (and (andmap (lambda (id) (and id (regexp-match? #px"^[0-9a-f]{64}$" id))) ids)
                 (andmap (lambda (id) (equal? id (car ids))) ids)))
          "trace: both peers of one session report the same OCapN Session ID")
  (define outbound
    (findf (lambda (ev) (and (msg? ev) (equal? (hash-ref ev 'op #f) "trace-me")
                             (hash-ref ev 'outbound)))
           events))
  (define inbound
    (findf (lambda (ev) (and (msg? ev) (equal? (hash-ref ev 'op #f) "trace-me")
                             (not (hash-ref ev 'outbound))))
           events))
  (expect outbound "trace: the client's send traced outbound")
  (expect inbound "trace: the server's deliver traced inbound")
  (expect (not (equal? (hash-ref outbound 'session) (hash-ref inbound 'session)))
          "trace: each host names its own session row")
  (expect (and (regexp-match? #px"^[0-9a-f]{32}$" (hash-ref outbound 'digest ""))
               (equal? (hash-ref outbound 'digest) (hash-ref inbound 'digest)))
          "trace: both observers derive the same 128-bit wire-message digest")
  ;; Payload: both fact sites sit at the wire boundary (inbound dispatch,
  ;; the outbound drain), so both records carry the whole (sub-cap) frame
  ;; with its true length and the verb inside it.
  (for ([rec (list inbound outbound)])
    (let ([frame (base64-decode
                  (string->bytes/latin-1 (hash-ref rec 'bytes_b64)))])
      (expect (= (hash-ref rec 'len) (bytes-length frame))
              "trace: true length rides beside the frame")
      (expect (regexp-match? #rx#"trace-me" frame)
              "trace: the frame bytes contain the delivered verb")))
  (expect (member "ocapn.session-closed" kinds) "trace: the close reached the sink")
  (let ([meta (findf (lambda (ev) (equal? (hash-ref ev 'kind) "ocapn.session-meta"))
                     events)])
    (expect (and meta (equal? (hash-ref (hash-ref meta 'meta) 'label) "greeter-server"))
            "trace: the annotation reached the sink with its label")
    (expect (equal? (hash-ref meta 'session) (hash-ref outbound 'session))
            "trace: the annotation names the same session row the tap names"))
  (expect (let loop ([last -1] [rest events])
            (cond [(null? rest) #t]
                  [(< (hash-ref (car rest) 'sim_t_ns) last) #f]
                  [else (loop (hash-ref (car rest) 'sim_t_ns) (cdr rest))]))
          "trace: sim_t_ns is monotone"))
(printf "racket zig-smoke OK: the live trace produced the timeline schema for a whole conversation\n")

;; ── Off-turn settlement: a behavior defers onto a resolver vow ────────────────
;; The worker's behavior atomically defers its turn (`host-defer-turn`), parks
;; the resolver, and returns; the main
;; thread settles it later, top level, and the caller's send completes only
;; then. The broken arm exercises a second call's fresh resolver and the
;; caller hears the worker's own words.
(define rv-server (listen "127.0.0.1" 0))
(define rv-ready (make-semaphore 0))
(define rv-parked-ready (make-semaphore 0))
(define rv-parked (box #f))
(define rv-serve
  (thread
   (lambda ()
     (define hsession (accept rv-server))
     (define worker-host (session-host hsession))
     (host-publish worker-host "worker"
                            (lambda (method . args)
                              (define pair (host-defer-turn-if-answer worker-host))
                              (set-box! rv-parked pair)
                              (semaphore-post rv-parked-ready)
                              (void)))
     (semaphore-post rv-ready)
     (session-serve hsession))))
(define rv-session (open-test-session (tcp-locator "127.0.0.1" (server-port rv-server))))
(semaphore-wait rv-ready)
(define rv-worker (session-fetch rv-session "worker"))

;; The served wire callback has an actual FFI turn, unlike a near call
;; between Goblins actors. Tells retain no answer; calls below retain one.
(session-tell rv-session rv-worker 'notice)
(semaphore-wait rv-parked-ready)
(expect (not (unbox rv-parked)) "optional deferral: tells mint no resolver")

(define rv-reply-ch (make-channel))
(void (thread (lambda () (channel-put rv-reply-ch (session-send rv-session rv-worker 'work)))))
(semaphore-wait rv-parked-ready)
(expect (resolver? (unbox rv-parked)) "optional deferral: calls retain answer custody")
(resolver-fulfill! (unbox rv-parked) "computed off-turn")
(expect (equal? "computed off-turn" (channel-get rv-reply-ch))
        "resolver: the deferred answer settled off-turn")

(set-box! rv-parked #f)
(define rv-broke-ch (make-channel))
(void (thread
       (lambda ()
         (channel-put rv-broke-ch
                      (with-handlers ([(lambda (_) #t) (lambda (e) (exn-message e))])
                        (session-send rv-session rv-worker 'work))))))
(semaphore-wait rv-parked-ready)
(resolver-break! (unbox rv-parked) "worker gave up")
(define rv-broke (channel-get rv-broke-ch))
(expect (and (string? rv-broke) (regexp-match? #rx"worker gave up" rv-broke))
        "resolver: the break carries the worker's words")
(resolver-abandon! (unbox rv-parked) "already retired")
(set-box! rv-parked #f)
(define rv-abandoned-ch (make-channel))
(void (thread
       (lambda ()
         (channel-put rv-abandoned-ch
                      (with-handlers ([(lambda (_) #t) (lambda (e) (exn-message e))])
                        (session-send rv-session rv-worker 'work))))))
(semaphore-wait rv-parked-ready)
(resolver-abandon! (unbox rv-parked) "worker dropped")
(resolver-abandon! (unbox rv-parked) "worker dropped")
(expect (regexp-match? #rx"worker dropped" (channel-get rv-abandoned-ch))
        "resolver: abandonment is idempotent and breaks live deferred work")
(session-close! rv-session)
(server-close! rv-server)

(printf "racket zig-smoke OK: a behavior deferred its answer onto a resolver vow and settled off-turn\n")

;; ── Sturdyref enliven: durable (peer, swissnum) brought to life, then cached ──
;; The swissnum keys the bootstrap fetch, so a host publish under that name
;; answers the enliven (ADR-0012). The client enlivens a sturdyref, calls the
;; live capability, then enlivens the same swissnum again and gets the cached
;; reference with no new wire fetch.
(define en-server (listen "127.0.0.1" 0))
(define en-ready (make-semaphore 0))
(define en-ch (make-channel))
(define en-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put en-ch e))])
       (define hsession (accept en-server))
       (session-publish hsession "greeter"
                     (lambda (bcom)
                       (methods
                        [(hello) (sym "alive")])))
       ;; The host-wide porter answers every session, including the fresh
       ;; connection host-enliven's dial arm opens below.
       (host-publish (session-host hsession) "porter"
                              (lambda (method . args) (sym "ported")))
       (semaphore-post en-ready)
       ;; Serve the first client here while a sibling accepts the dial arm's
       ;; connection.
       (define second
         (thread
          (lambda ()
            (with-handlers ([(lambda (_) #t) void])
              (session-serve (accept en-server))))))
       (session-serve hsession)
       (thread-wait second)
       (channel-put en-ch 'served)))))

(define en-locator (tcp-locator "127.0.0.1" (server-port en-server)))
(define en-session (open-test-session en-locator))
(semaphore-wait en-ready)
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (session-enliven en-session "ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg")
          #f)
        "enliven: a sturdyref for another peer is refused")
;; The complete sturdyref must name this selected session's peer.
(define en-sturdyref (string-append (format-locator-uri en-locator) "/s/Z3JlZXRlcg"))
(define en-cap (session-enliven en-session en-sturdyref))
(expect (ref? en-cap) "enliven: a sturdyref enlivened to a capability")
(expect (equal? (sym "alive") (session-send en-session en-cap 'hello)) "enliven: the live capability answers hello")
;; A repeat enliven hits the dedup cache: the same live reference, no wire fetch.
(define en-again (session-enliven en-session en-sturdyref))
(expect (equal? en-again en-cap) "enliven: a repeat enliven hits the cache")
(expect (equal? (sym "alive") (session-send en-session en-again 'hello)) "enliven: the cached capability answers hello")
;; Listen (CapTP op:listen): a held capability's resolution comes back through
;; the vow. A listen on an already-settled capability answers at once.
(define en-observation (session-listen en-session en-cap))
(define en-observer-refusal
  (with-handlers ([exn:fail:glowcap? values])
    (session-send en-session en-observation 'hello)
    'no-error))
(expect (and (exn:fail:glowcap? en-observer-refusal)
             (= ERR-INVALID-ARGUMENT (exn:fail:glowcap-code en-observer-refusal)))
        "listen: an observer vow is not a remote pipeline target")
(define en-listened (session-await en-session en-observation))
(expect (ref? en-listened) "listen: the vow settles naming the capability")

;; Host-level select-or-dial enliven (ADR-0098). SELECT: the sturdyref names
;; a peer this host already dialed, so the enliven rides `en-session` and the
;; capability answers there.
(define hs-cap
  (host-enliven (session-host en-session) en-sturdyref #:captp-version 'v1_0))
(expect (ref? hs-cap) "host-enliven: selected a live dialed session")
(expect (equal? (sym "alive") (session-send en-session hs-cap 'hello))
        "host-enliven: explicit v1.0 swiss semantics select the live authority")
(define fetched-at (host-fetch-at (session-host en-session) en-locator "greeter"))
(expect (equal? (sym "alive") (session-send en-session fetched-at 'hello))
        "host-fetch-at: typed locator uses the host's configured profile")
;; DIAL: a fresh host with no session stages a dial through the action queue,
;; the executor opens the exporter session on its own serve thread, and the
;; host-scoped wait settles over it.
(define dial-host (make-fresh-host))
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (host-enliven dial-host en-sturdyref
                        #:captp-version 'unknown
                        #:connector (tcp-connector))
          #f)
        "host-enliven: an unknown explicit version is refused")
(expect (not (host-connector-for dial-host TRANSPORT-TCP))
        "host-enliven: version refusal leaves connector authority unchanged")
(define dial-cap
  (host-enliven dial-host (string-append (format-locator-uri en-locator) "/s/cG9ydGVy")
                #:captp-version 'v1_0
                #:connector (tcp-connector)))
(expect (ref? dial-cap) "host-enliven: a cold sturdyref staged a dial and settled")
(host-close! dial-host)

(session-close! en-session)
(define en-host-result (channel-get en-ch))
(when (exn? en-host-result) (raise en-host-result))
(expect (eq? 'served en-host-result) "enliven: host served to a clean close")
(server-close! en-server)

(printf "racket zig-smoke OK: a sturdyref enlivens to a live capability, a repeat enliven hits the cache, and a listen settles\n")

;; ── The codec host option: a Cap'n Proto session end to end ──────────────────
;; `listen`/`connect` take `#:codec`: both ends here negotiate Cap'n Proto, so
;; the keyed handshake, the fetch, and the reply all ride capnp frames (the
;; core's stream delimiter splits them behind the pump's byte feed, word shape
;; and all). The echoed args
;; include a big integer past int64 and a keyword, so the two rare marshal
;; arms are witnessed alongside the codec.
(define cx-server (listen "127.0.0.1" 0 #:codec 'capnp))
(define cx-ready (make-semaphore 0))
(define cx-ch (make-channel))
(define cx-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put cx-ch e))])
       (define hsession (accept cx-server))
       (session-publish hsession "board"
                     (lambda (bcom)
                       (methods
                        [(echo big k bs record err) (list big k bs record err)]
                        [(ints xs) (equal? xs '(7 -8 9))])))
       (semaphore-post cx-ready)
       (session-serve hsession)
       (channel-put cx-ch 'served)))))
(define cx-session (open-test-session (tcp-locator "127.0.0.1" (server-port cx-server)) #:codec 'capnp))
(semaphore-wait cx-ready)
(define cx-svc (session-fetch cx-session "board"))
(define cx-big (expt 2 80))
(define cx-struct (struct-arg (list (cons "count" 7) (cons "name" "widget"))))
(define cx-error (error-arg "failure is a value"))
(expect (equal? (list cx-big (kw "prio") #"hi" cx-struct cx-error)
                (session-send cx-session cx-svc 'echo cx-big (kw "prio") #"hi" cx-struct cx-error))
        "capnp: big-integer + keyword + bytes + Struct + Error args round-trip a Cap'n Proto session")
(expect (eq? #t (session-send cx-session cx-svc 'ints (list->s64vector '(7 -8 9))))
        "capnp: an s64vector argument arrives as a list of 7, -8, 9")
(session-close! cx-session)
(define cx-host-result (channel-get cx-ch))
(when (exn? cx-host-result) (raise cx-host-result))
(expect (eq? 'served cx-host-result) "capnp: host served to a clean close")
(server-close! cx-server)

(printf "racket zig-smoke OK: a capnp session opens and big-integer + keyword + Struct + Error args round-trip\n")
