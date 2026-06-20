#lang racket/base
;; Racket dogfood of the Zig pancake C ABI archives, through the idiomatic
;; composable modules — the core peer in `pancake.rkt` plus one module per
;; transport archive (`pancake-tcp.rkt`, `pancake-inproc.rkt`), composed à la
;; carte exactly as a C consumer links the archives. It drives OCapN with native
;; Racket values and event structs — no FFI in sight. This is the consumer
;; `zig build bindings` runs.

(require "pancake.rkt"
         "pancake-tcp.rkt"
         "pancake-inproc.rkt"
         ffi/unsafe
         racket/tcp)

;; Line-buffer the OK lines so a failure can never swallow the progress that
;; preceded it.
(file-stream-buffer-mode (current-output-port) 'line)

(define (fail msg) (eprintf "racket zig-smoke FAILED: ~a\n" msg) (exit 1))
(define (expect cond msg) (unless cond (fail msg)))

;; The linked library reports a real ABI version.
(let-values ([(major minor patch) (abi-version)])
  (expect (positive? (+ major minor patch)) "abi-version is nonzero"))

;; Construct a call with native args, then read it back as a typed event.
(define caller (make-peer/raw-open))
(peer-register-import! caller 5)
(peer-send-deliver! caller (far 5) (list 42 #"hi") #:answer 9)
(peer-step! caller)
(define wire (peer-take-outbound caller))
(expect (and wire (regexp-match? #rx#"^<10'op:deliver" wire)) "constructed a real op:deliver")
(peer-release! caller)

(define callee (make-peer/raw-open))
(peer-register-export! callee 7)
(peer-feed! callee #"<10'op:deliver<11'desc:export7+>[5:hello]11+f>")
(define ev (peer-poll callee))
(expect (deliver-event? ev) "got a deliver event")
(expect (and (near-ref? (deliver-event-target ev)) (= 7 (near-ref-id (deliver-event-target ev)))) "target near export 7")
(expect (= 11 (deliver-event-answer ev)) "answer is 11")
(expect (equal? (deliver-event-args ev) (list #"hello")) "one bytes arg 'hello'")
(peer-release! callee)

;; A context with a host allocator backs a peer; feed-owned transfers the frame
;; into the inbound queue and the deliver still surfaces. The custom allocator
;; counts blocks so we prove the library routed through it.
(define alloc-count (box 0))
(define ctx
  (make-context/allocator
   (lambda (size alignment)
     (set-box! alloc-count (add1 (unbox alloc-count)))
     (malloc 'raw (max size 1)))
   (lambda (ptr size alignment) (free ptr))))
(define owned-callee (make-peer/raw-open/in ctx))
(peer-register-export! owned-callee 7)
(peer-feed-owned! owned-callee #"<10'op:deliver<11'desc:export7+>[5:hello]11+f>")
(peer-step! owned-callee)
(define owned-ev (peer-poll owned-callee))
(expect (deliver-event? owned-ev) "feed-owned: got a deliver event")
(expect (and (near-ref? (deliver-event-target owned-ev)) (= 7 (near-ref-id (deliver-event-target owned-ev))))
        "feed-owned: target near export 7")
(expect (= 11 (deliver-event-answer owned-ev)) "feed-owned: answer is 11")
(expect (equal? (deliver-event-args owned-ev) (list #"hello")) "feed-owned: one bytes arg 'hello'")
(expect (positive? (unbox alloc-count)) "host allocator was used by the context")
(peer-release! owned-callee)
(context-release! ctx)

;; An inbound abort surfaces as a typed event.
(define peer (make-peer/raw-open))
(peer-feed! peer #"<8'op:abort3\"bye>")
(define abort (peer-poll peer))
(expect (and (other-event? abort) (= 7 (other-event-kind abort))) "abort surfaced as a typed event")
(expect (not (peer-poll peer)) "no further events")
(peer-release! peer)

;; ── Goblins for Racket: a counter actor, near-called and eventual-sent ────────
;; A Goblins-faithful actor: a constructor `(^counter bcom n)` the vat calls once
;; at spawn, returning a behavior built with `methods` that dispatches on a
;; leading method symbol. `add` becomes a fresh behavior over the new total via
;; `bcom`; `get` reports the current total. We spawn it in a vat, near-call it
;; with `$`, then eventual-send with `<-` and observe the vow with `on`.
(define (^counter bcom n)
  (methods
   [(add k) (bcom (^counter bcom (+ n k)) (+ n k))]
   [(get)   n]))

(define demo-vat (make-vat))
(with-vat demo-vat
  ;; Near-call: `$` runs the behavior synchronously, here and now.
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

;; ── Hosting: publish a counter on a peer and serve an inbound deliver ─────────
;; Publish a counter at export 7, feed an `op:deliver` carrying `counter.add(5)`
;; with answer 11 (where `3'add` is the OCapN symbol "add") and a V1.0 resolver
;; callback, serve the polled event into the vat, step, and assert the outbound
;; resolver-callback deliver fulfils 15.
(define host-peer (make-peer/raw-open))
(define host-vat (make-vat #:peer host-peer))
(with-vat host-vat
  (publish! host-vat (spawn ^counter 10) 7))
(peer-feed! host-peer #"<10'op:deliver<11'desc:export7+>[3'add5+]11+<19'desc:import-promise99+>>")
(define host-ev (peer-poll host-peer))
(expect (deliver-event? host-ev) "host: got a deliver event")
(expect (vat-serve! host-vat host-ev) "host: vat served the deliver")
(peer-step! host-peer)
(define host-wire (peer-take-outbound host-peer))
(expect (and host-wire (regexp-match? #rx#"op:deliver" host-wire)) "host: replied with resolver-callback deliver")
(expect (and host-wire (regexp-match? #rx#"fulfill" host-wire)) "host: resolver callback fulfilled")
(expect (and host-wire (regexp-match? #rx#"15\\+" host-wire)) "host: counter.add(5) fulfilled with 15")
(peer-release! host-peer)

(printf "racket zig-smoke OK: hosted a Goblins actor on an OCapN export\n")

;; ── PreSpec profile construction ─────────────────────────────────────────────
(define prespec-peer (make-peer #:version 'pre-spec))
(peer-start-session! prespec-peer
                     (make-bytes 32 #x77)
                     #:designator "127.0.0.1:77")
(peer-step! prespec-peer)
(define prespec-wire (peer-take-outbound prespec-peer))
(expect (and prespec-wire (regexp-match? #rx#"op:start-session" prespec-wire))
        "prespec: queued an authenticated start-session")
(peer-release! prespec-peer)

(printf "racket zig-smoke OK: queued an authenticated PreSpec start-session\n")

;; ── The local|far seam: a vat far-send round-trip ────────────────────────────
;; peerB's vat publishes a counter at export 7; peerA's vat far-sends
;; `(<- (far 7) 'add 5)` through the seam, no hand-built wire message. Shuttle
;; A's outbound deliver to B and serve it (10 -> 15, resolves), shuttle the
;; resolver-callback deliver back, and serve the typed resolve event on A to fire
;; the far vow. This is the same
;; location-transparent round-trip the Rust, Python, and Deno smokes prove.
(define fa-peer (make-peer/raw-open))
(define fb-peer (make-peer/raw-open))
(define fa-vat (make-vat #:peer fa-peer))
(define fb-vat (make-vat #:peer fb-peer))
(with-vat fb-vat (publish! fb-vat (spawn ^counter 10) 7))
(peer-register-import! fa-peer 7)

(define far-observed (box #f))
(define far-vow (with-vat fa-vat (<- (far 7) 'add 5)))
(with-vat fa-vat (on far-vow (lambda (total) (set-box! far-observed total))))

;; A's `<-` queued an `op:deliver`; encode it and hand it to B.
(peer-step! fa-peer)
(define fa-wire (peer-take-outbound fa-peer))
(expect (and fa-wire (regexp-match? #rx#"op:deliver" fa-wire)) "far: A produced an outbound deliver")
(peer-feed! fb-peer fa-wire)
(define fb-ev (peer-poll fb-peer))
(expect (deliver-event? fb-ev) "far: B received the deliver")
(expect (vat-serve! fb-vat fb-ev) "far: B's published actor served it")

;; B's V1.0 resolver-callback deliver goes back to A; the peer surfaces it as a
;; typed resolve event, and serving it fires the far vow's listener.
(peer-step! fb-peer)
(define fb-wire (peer-take-outbound fb-peer))
(expect (and fb-wire (regexp-match? #rx#"op:deliver" fb-wire)) "far: B produced an outbound resolver callback")
(peer-feed! fa-peer fb-wire)
(define fa-ev (peer-poll fa-peer))
(expect (resolve-event? fa-ev) "far: A received the resolve")
(expect (vat-serve! fa-vat fa-ev) "far: A served the resolve, firing the far vow")
(expect (= 15 (unbox far-observed)) "far: (<- (far 7) 'add 5) settled the far vow with 15")
(peer-release! fa-peer)
(peer-release! fb-peer)

(printf "racket zig-smoke OK: far-send round-trip across the local|far seam\n")

;; ── Disconnect: break-far-vows! settles a pending far vow as broken ───────────
;; A far vow waits on a resolve that rides the wire; if the connection drops it
;; can never arrive, so `break-far-vows!` settles the vow broken and the
;; `#:catch` handler runs instead of the awaiter waiting forever.
(define dc-peer (make-peer/raw-open))
(peer-register-import! dc-peer 5)
(define dc-vat (make-vat #:peer dc-peer))
(define dc-broken (box #f))
(define dc-vow (with-vat dc-vat (<- (far 5) 'add 5)))
(with-vat dc-vat (on dc-vow #f #:catch (lambda (msg) (set-box! dc-broken msg))))
(break-far-vows! dc-vat "connection closed")
(expect (equal? "connection closed" (unbox dc-broken))
        "disconnect: break-far-vows! fired the far vow's #:catch handler")
(peer-release! dc-peer)

(printf "racket zig-smoke OK: break-far-vows! settles a pending far vow on disconnect\n")

;; ── Async: drive two peers over real Racket TCP ports ─────────────────────────
;; A server thread listens on an ephemeral port, accepts, hosts export 7, and
;; replies to the first deliver with a Fulfill. The main thread connects,
;; imports 7, calls far(7) with answer 9, and asserts the Resolve settling 9.
(define listener (tcp-listen 0 4 #t "127.0.0.1"))
(define-values (_lh raw-server-port _rh _rp) (tcp-addresses listener #t))
(define result-ch (make-channel))

(define server
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put result-ch e))])
       (define-values (sin sout) (tcp-accept listener))
       (define speer (make-peer/raw-open))
       (peer-register-export! speer 7)
       (define sconn (async-connection/ports speer sin sout))
       (define ev (async-next-event sconn))
       (expect (deliver-event? ev) "server: got a deliver event")
       (expect (and (near-ref? (deliver-event-target ev)) (= 7 (near-ref-id (deliver-event-target ev))))
               "server: target near export 7")
       (define answer (deliver-event-answer ev))
       (expect answer "server: deliver carried an answer")
       (async-send-resolve! sconn answer (fulfill #"pong"))
       (channel-put result-ch 'done)))))

(define-values (client-in client-out) (tcp-connect "127.0.0.1" raw-server-port))
(define client-conn (async-connection/ports (make-peer/raw-open) client-in client-out))
(peer-register-import! (async-connection-peer client-conn) 7)
(async-send-deliver! client-conn (far 7) (list #"ping") #:answer 9)
(define resolve-ev (async-next-event client-conn))
(expect (resolve-event? resolve-ev) "client: got a resolve event")
(expect (= 9 (resolve-event-answer resolve-ev)) "client: resolve settles answer 9")
(expect (and (fulfill? (resolve-event-resolution resolve-ev))
             (equal? #"pong" (fulfill-value (resolve-event-resolution resolve-ev))))
        "client: fulfilled with #\"pong\"")

;; Surface any server-side failure.
(define server-result (channel-get result-ch))
(when (exn? server-result) (raise server-result))
(expect (eq? 'done server-result) "server completed cleanly")
(tcp-close listener)

(printf "racket zig-smoke OK: drove async OCapN over Racket TCP ports\n")

;; ── Hosting: high-level listen/accept against connect ─────────────────────────
;; A host thread listens on an ephemeral port, accepts one partner on the
;; high-level surface, publishes `svc`, and serves. The main thread `connect`s,
;; fetches `svc`, calls it, and reads the reply off the far vow, a keyed
;; op:start-session handshake on both ends, no peer or vat wired by hand.
(define hl-server (listen "127.0.0.1" 0))
(define hl-ready (make-semaphore 0))
(define hl-ch (make-channel))
(define hl-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put hl-ch e))])
       (define hconn (accept hl-server))
       (conn-publish hconn "svc"
                     (lambda (bcom)
                       (methods
                        [(greet who) (string-append "hello " who)])))
       (semaphore-post hl-ready)
       (conn-serve hconn)
       (channel-put hl-ch 'served)))))

;; `accept` blocks until someone dials, so connect first, then wait for the
;; publish before fetching.
(define hl-conn (connect (tcp-locator "127.0.0.1" (server-port hl-server))))
(semaphore-wait hl-ready)
(define hl-svc (conn-fetch hl-conn "svc"))
(define hl-reply (box 'pending))
(with-vat (conn-vat hl-conn)
  (on (<- hl-svc 'greet "pancake")
      (lambda (v) (set-box! hl-reply v))
      #:catch (lambda (msg) (set-box! hl-reply (cons 'broken msg)))))
(async-flush! (conn-async hl-conn))
(let loop ()
  (when (eq? 'pending (unbox hl-reply))
    (define ev (async-next-event (conn-async hl-conn)))
    (when (eof-object? ev) (fail "listen/accept: connection closed before the reply"))
    (vat-serve! (conn-vat hl-conn) ev)
    (loop)))
(expect (equal? "hello pancake" (unbox hl-reply)) "listen/accept: high-level call round-tripped")
(connection-close! hl-conn)
(define hl-host-result (channel-get hl-ch))
(when (exn? hl-host-result) (raise hl-host-result))
(expect (eq? 'served hl-host-result) "listen/accept: host served to a clean close")
(server-close! hl-server)

(printf "racket zig-smoke OK: high-level listen/accept hosted a keyed session\n")

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
       (define hconn (accept en-server))
       (conn-publish hconn "greeter"
                     (lambda (bcom)
                       (methods
                        [(hello) (sym "alive")])))
       (semaphore-post en-ready)
       (conn-serve hconn)
       (channel-put en-ch 'served)))))

(define en-conn (connect (tcp-locator "127.0.0.1" (server-port en-server))))
(semaphore-wait en-ready)
;; The connection is already open; enliven keys on the sturdyref's swissnum,
;; carried by the URI as `/s/greeter`.
(define en-sturdyref "ocapn://greeter-host.tcp/s/greeter")
(define en-cap (conn-enliven en-conn en-sturdyref))
(expect (far-ref? en-cap) "enliven: a sturdyref enlivened to a far capability")
(expect (equal? (sym "alive") (conn-send en-conn en-cap 'hello)) "enliven: the live capability answers hello")
;; A repeat enliven hits the dedup cache: the same live reference, no wire fetch.
(define en-again (conn-enliven en-conn en-sturdyref))
(expect (equal? en-again en-cap) "enliven: a repeat enliven hits the cache")
(expect (equal? (sym "alive") (conn-send en-conn en-again 'hello)) "enliven: the cached capability answers hello")
(connection-close! en-conn)
(define en-host-result (channel-get en-ch))
(when (exn? en-host-result) (raise en-host-result))
(expect (eq? 'served en-host-result) "enliven: host served to a clean close")
(server-close! en-server)

(printf "racket zig-smoke OK: a sturdyref enlivens to a live capability, and a repeat enliven hits the cache\n")

;; ── Distributed GC (ADR-0063): a dropped fetched import releases its export ──
;; Opt the client into GC; once on, a far capability returned by `conn-fetch`
;; releases its import — one `op:gc-export` — when the collector reclaims the last
;; reference to it. The host here is a hand-driven raw peer over the same TCP
;; ports the client's `connect` speaks, so it can watch the inbound wire bytes for
;; that release frame (the engine consumes `op:gc-export` internally, so it never
;; surfaces as an event — only the raw frame proves it shipped). The client
;; fetches a cap inside a thunk so it falls out of scope, drops it, and forces
;; collection; the finalizer parks the release, and the next `conn-fetch` drains
;; it to the wire where the host sees it.
(define gc-listener (tcp-listen 0 4 #t "127.0.0.1"))
(define-values (_gch gc-port _gcrh _gcrp) (tcp-addresses gc-listener #t))
(define gc-saw (box #f))
(define gc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define-values (sin sout) (tcp-accept gc-listener))
       (define hp (make-peer))
       (peer-register-bootstrap-cap! hp #"svc")
       (peer-start-session! hp (make-bytes 32 12) #:designator "127.0.0.1:1")
       (define (pump!)
         (peer-step-to-idle! hp)
         (let drain () (define f (peer-take-outbound hp)) (when f (write-bytes f sout) (drain)))
         (flush-output sout))
       (pump!) ; ship the host's op:start-session before blocking on a read
       ;; Accumulate inbound bytes; sniff each new chunk for the release frame,
       ;; then feed whole frames to the peer so it answers the bootstrap fetches
       ;; (whose resolutions the client waits on) and processes the gc-export.
       (let loop ([inbox #""])
         (define buf (make-bytes 65536))
         (define n (read-bytes-avail! buf sin))
         (cond
           [(eof-object? n) (void)]
           [else
            (when (regexp-match? #rx#"op:gc-export" (subbytes buf 0 n)) (set-box! gc-saw #t))
            (let consume ([bs (bytes-append inbox (subbytes buf 0 n))])
              (define taken (peer-recv-stream! hp bs))
              (cond
                [taken (consume (subbytes bs taken))]
                [else (pump!) (loop bs)]))]))))))

(define gc-conn (conn-with-gc! (connect (tcp-locator "127.0.0.1" gc-port))))
;; Fetch and drop inside a thunk so the capability falls out of scope (a
;; module-level binding would root it forever and never finalize).
(define (gc-fetch-and-drop!)
  (define cap (conn-fetch gc-conn "svc"))
  (expect (far-ref? cap) "gc: fetched a far import")
  (void))
(gc-fetch-and-drop!)
;; Force collection, then re-fetch to drain the parked release, until the host
;; sees the gc-export (or we exhaust the budget).
(let loop ([i 0])
  (collect-garbage)
  (sleep 0.02)
  (conn-fetch gc-conn "svc")
  (unless (or (unbox gc-saw) (>= i 100)) (loop (add1 i))))
(expect (unbox gc-saw) "gc: host observed op:gc-export for the dropped fetched import")
(connection-close! gc-conn)
(void (sync/timeout 1 (thread-dead-evt gc-host))) ; the host loop ends on the client's close
(tcp-close gc-listener)

(printf "racket zig-smoke OK: a dropped fetched import releases its export when GC is opted in\n")

;; ── Bounded inbox: an over-cap frame is a typed refusal, not "read more" ──────
;; A connection's inbox keeps growing only while peer-recv-stream! returns #f
;; (WOULD-BLOCK); a frame declaring more than max_frame_bytes must surface as
;; the typed FRAME_TOO_LARGE error (-11), or a hostile partner could grow the
;; inbox without bound.
(define oc-peer (make-peer/raw-open))
(peer-register-export! oc-peer 7)
(define oc-code
  (with-handlers ([exn:fail:pancake? (lambda (e) (exn:fail:pancake-code e))])
    (peer-recv-stream! oc-peer #"<10'op:deliver<11'desc:export7+>[2000000:")
    'no-error))
(expect (equal? -11 oc-code) "over-cap frame: typed FRAME_TOO_LARGE refusal")
(peer-release! oc-peer)

(printf "racket zig-smoke OK: an over-cap frame refuses typed instead of buffering\n")

;; ── last-abort: a refused frame carries its typed cause ───────────────────────
;; The flat return code names the failure family; `peer-last-abort` — and the
;; `abort` field on the exn a feeding call raises — names the member: domain,
;; projected op:abort kind, and the originating error.
(define la-peer (make-peer/raw-open))
(expect (not (peer-last-abort la-peer)) "last-abort: nothing recorded before a failure")
(define la-exn
  (with-handlers ([exn:fail:pancake? values])
    (peer-feed! la-peer #"this is not a frame")
    'no-error))
(expect (exn:fail:pancake? la-exn) "last-abort: a refused frame raised exn:fail:pancake")
(define la-info (exn:fail:pancake-abort la-exn))
(expect (abort-info? la-info) "last-abort: the exn carries the typed abort detail")
(expect (eq? 'codec (abort-info-domain la-info)) "last-abort: domain is codec")
(expect (equal? "MalformedFrame" (abort-info-kind la-info)) "last-abort: kind is MalformedFrame")
(expect (equal? "MalformedFrame" (abort-info-error-name la-info)) "last-abort: error-name is MalformedFrame")
(expect (abort-info? (peer-last-abort la-peer)) "last-abort: the getter reads the same recorded cause")
(peer-release! la-peer)

(printf "racket zig-smoke OK: a refused frame carries its typed last-abort cause\n")

;; ── Connection parity: self-spawned sends resolve in process; failures are typed ─
;; A host publishes `svc` (whose `boom` method raises) and serves. The client
;; proves three contracts the other bindings already pin: a send/tell to a Ref
;; this same connection spawned resolves in process (the server hosts no such
;; export, so a wire route would never reply, mirroring Rust's
;; send_to_a_self_spawned_actor_resolves_in_process); a partner break raises a
;; typed exn:fail:pancake carrying PANCAKE_ERR_BROKEN; and a failed fetch
;; re-raises that typed failure untouched.
(define cp-server (listen "127.0.0.1" 0))
(define cp-ready (make-semaphore 0))
(define cp-ch (make-channel))
(define cp-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put cp-ch e))])
       (define hconn (accept cp-server))
       (conn-publish hconn "svc"
                     (lambda (bcom)
                       (methods
                        [(boom) (error 'svc "deliberate failure")])))
       (semaphore-post cp-ready)
       (conn-serve hconn)
       (channel-put cp-ch 'served)))))

(define cp-conn (connect (tcp-locator "127.0.0.1" (server-port cp-server))))
(semaphore-wait cp-ready)

;; Self-spawned send and tell: the client never runs a serve loop, so only an
;; in-process turn can settle these.
(define cp-me (conn-spawn cp-conn ^counter 10))
(expect (near-ref? cp-me) "self-spawn: conn-spawn returns a near capability")
(expect (= 15 (conn-send cp-conn cp-me 'add 5)) "self-spawn: conn-send resolved in process")
(conn-tell cp-conn cp-me 'add 100)
(expect (= 115 (conn-send cp-conn cp-me 'get)) "self-spawn: conn-tell ran the local turn")

;; A partner break is a typed pancake failure carrying PANCAKE_ERR_BROKEN (-14).
(define cp-svc (conn-fetch cp-conn "svc"))
(define cp-broken
  (with-handlers ([exn:fail:pancake? values])
    (conn-send cp-conn cp-svc 'boom)
    'no-error))
(expect (exn:fail:pancake? cp-broken) "break: conn-send raised exn:fail:pancake")
(expect (equal? -14 (exn:fail:pancake-code cp-broken)) "break: code is PANCAKE_ERR_BROKEN")

;; A fetch of an unpublished name breaks too, and conn-fetch re-raises the typed
;; failure untouched instead of flattening it to a generic exn:fail.
(define cp-missing
  (with-handlers ([exn:fail:pancake? values])
    (conn-fetch cp-conn "no-such-name")
    'no-error))
(expect (exn:fail:pancake? cp-missing) "fetch: an unknown name raised exn:fail:pancake")
(expect (equal? -14 (exn:fail:pancake-code cp-missing)) "fetch: code is PANCAKE_ERR_BROKEN")

(connection-close! cp-conn)
(define cp-host-result (channel-get cp-ch))
(when (exn? cp-host-result) (raise cp-host-result))
(expect (eq? 'served cp-host-result) "connection parity: host served to a clean close")
(server-close! cp-server)

(printf "racket zig-smoke OK: self-spawned sends resolve in process and failures are typed\n")

;; ── Promise pipelining: the questioner's half (ADR-0007) ──────────────────────
;; `conn-send-promise` returns a `promise-ref` that is itself a `send` target, so
;; a create -> assign -> complete -> status chain is issued against the
;; *unresolved* create answer and the four delivers travel as one batch on the
;; settling `conn-send`'s flush. The board's `create` spawns a fresh task and
;; returns it; the partner's engine queues the pipelined calls on that pending
;; answer and drains them onto the task once create resolves. A status of `done`
;; proves the chain crossed the wire without round-tripping per link.
(define (^task bcom [done #f])
  (methods
   [(assign who) "assigned"]
   [(complete)   (bcom (^task bcom #t) "done")]
   [(status)     (if done "done" "open")]))

(define pl-server (listen "127.0.0.1" 0))
(define pl-ready (make-semaphore 0))
(define pl-ch (make-channel))
(define pl-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pl-ch e))])
       (define hconn (accept pl-server))
       (conn-publish hconn "root"
                     (lambda (bcom)
                       (methods
                        [(create name) (conn-spawn hconn ^task)])))
       (semaphore-post pl-ready)
       (conn-serve hconn)
       (channel-put pl-ch 'served)))))

(define pl-conn (connect (tcp-locator "127.0.0.1" (server-port pl-server))))
(semaphore-wait pl-ready)
(define pl-root (conn-fetch pl-conn "root"))
;; The four verbs leave together: none waits for create's reply, and assign /
;; complete / status target the create answer directly.
(define pl-task (conn-send-promise pl-conn pl-root 'create "benchmark"))
(void (conn-send-promise pl-conn pl-task 'assign "alice"))
(void (conn-send-promise pl-conn pl-task 'complete))
(define pl-status (conn-send pl-conn pl-task 'status))
(expect (equal? "done" pl-status) "pipelining: the chained status settled to done")

(connection-close! pl-conn)
(define pl-host-result (channel-get pl-ch))
(when (exn? pl-host-result) (raise pl-host-result))
(expect (eq? 'served pl-host-result) "pipelining: host served to a clean close")
(server-close! pl-server)

(printf "racket zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch\n")

;; ── Pipelined projections (ADR-0050/ADR-0052) ─────────────────────────────────
;; `conn-untag`/`conn-index`/`conn-get` project a tag/element/field out of a far
;; vow *before it settles*, each returning a new pipelinable vow. The board's
;; `make` returns a `("assigned" label 7)` row wrapped in a "task" tag; `untag`
;; unwraps the single-value tag to that row and `index 1` takes the label, a
;; two-hop chain riding the unresolved `make` answer, no extra round trip. The
;; source vow is then awaited to prove a far reply that landed *before* its
;; listener (while a sibling projection pumped the loop) still settles from the
;; stash. (`get` projects a Struct, which the Racket value model surfaces as a
;; tagged/struct arg; index and untag are the cross-binding-comparable pair, so
;; they are what this dogfood asserts, matching Python.)
(define pj-server (listen "127.0.0.1" 0))
(define pj-ready (make-semaphore 0))
(define pj-ch (make-channel))
(define pj-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pj-ch e))])
       (define hconn (accept pj-server))
       (conn-publish hconn "root"
                     (lambda (bcom)
                       (methods
                        [(make label) (tagged-arg "task" (list (list "assigned" label 7)))])))
       (semaphore-post pj-ready)
       (conn-serve hconn)
       (channel-put pj-ch 'served)))))

(define pj-conn (connect (tcp-locator "127.0.0.1" (server-port pj-server))))
(semaphore-wait pj-ready)
(define pj-root (conn-fetch pj-conn "root"))
;; Neither projection waits for make's reply: they ride the unresolved make
;; answer and the whole chain leaves on one flush.
(define pj-made (conn-send-promise pj-conn pj-root 'make "alice"))
(define pj-label (conn-await pj-conn (conn-index pj-conn (conn-untag pj-conn pj-made "task") 1)))
(expect (equal? "alice" pj-label) "projections: pipelined untag->index reached the label")
;; The source answer settled while the projection pumped the loop; awaiting it
;; now must still resolve from the stash.
(define pj-full (conn-await pj-conn pj-made))
(expect (and (tagged-arg? pj-full) (equal? "task" (tagged-arg-tag pj-full)))
        "projections: the late source await still settled to the tagged row")

(connection-close! pj-conn)
(define pj-host-result (channel-get pj-ch))
(when (exn? pj-host-result) (raise pj-host-result))
(expect (eq? 'served pj-host-result) "projections: host served to a clean close")
(server-close! pj-server)

(printf "racket zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles\n")

;; ── Object-capability forwarding proxies over the wire (ADR-0064) ─────────────
;; The client spawns a local tool and passes it as an argument to the host, which
;; sees a far reference and wraps it in a caretaker and an attenuator, handing the
;; proxies back. A call through the caretaker proxy forwards across the host back
;; to the client's tool (the far deferred-answer path) and settles the caller's
;; answer; the attenuator passes only its allow-listed verb; and a revoke breaks
;; every later call.
(define (^tool bcom)
  (methods
   [(add n) (+ n 1)]
   [(get) 7]))

(define mb-server (listen "127.0.0.1" 0))
(define mb-ready (make-semaphore 0))
(define mb-ch (make-channel))
(define mb-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put mb-ch e))])
       (define hconn (accept mb-server))
       ;; The caretaker the host hands out, stashed so `revoke` can sever it.
       (define proxy-box (box #f))
       (conn-publish hconn "root"
                     (lambda (bcom)
                       (methods
                        [(make-proxy tool)
                         (define proxy (conn-caretaker hconn tool))
                         (set-box! proxy-box proxy)
                         proxy]
                        [(make-readonly tool) (conn-attenuate hconn tool '("get"))]
                        [(revoke) (conn-revoke! hconn (unbox proxy-box)) "revoked"])))
       (semaphore-post mb-ready)
       (conn-serve hconn)
       (channel-put mb-ch 'served)))))

(define mb-conn (connect (tcp-locator "127.0.0.1" (server-port mb-server))))
(semaphore-wait mb-ready)
(define mb-tool (conn-spawn mb-conn ^tool))
(define mb-root (conn-fetch mb-conn "root"))

;; Live caretaker: a call forwards across the host to the client's far tool.
(define mb-proxy (conn-send mb-conn mb-root 'make-proxy mb-tool))
(expect mb-proxy "proxy: the host returned a caretaker proxy")
(expect (= 42 (conn-send mb-conn mb-proxy 'add 41)) "proxy: caretaker forwards to the far tool")

;; Attenuator: the allow-listed verb forwards; any other breaks.
(define mb-ro (conn-send mb-conn mb-root 'make-readonly mb-tool))
(expect (= 7 (conn-send mb-conn mb-ro 'get)) "proxy: attenuator forwards an allowed verb")
(define mb-denied
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (conn-send mb-conn mb-ro 'add 1) #f))
(expect (and (exn:fail:pancake? mb-denied)
             (regexp-match? #rx"Attenuated" (exn-message mb-denied)))
        "proxy: an out-of-list verb breaks Attenuated")

;; Revoke: every later call through the proxy breaks.
(void (conn-send mb-conn mb-root 'revoke))
(define mb-severed
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (conn-send mb-conn mb-proxy 'add 1) #f))
(expect (and (exn:fail:pancake? mb-severed)
             (regexp-match? #rx"Revoked" (exn-message mb-severed)))
        "proxy: a revoked proxy breaks Revoked")

(connection-close! mb-conn)
(define mb-host-result (channel-get mb-ch))
(when (exn? mb-host-result) (raise mb-host-result))
(expect (eq? 'served mb-host-result) "proxy: host served to a clean close")
(server-close! mb-server)

(printf "racket zig-smoke OK: forwarding proxies forward, attenuate, and revoke over the wire\n")

;; ── A forwarding proxy answers its host's own local call (ADR-0064) ────────────
;; The wart ADR-0064 closes: a caretaker proxy is an ordinary spawned actor, so
;; its own host calls it locally exactly as a partner calls it over the wire. A
;; caretaker over a *local* tool answers a local send; a caretaker over a *far*
;; tool forwards across the wire and the local send still settles; and a revoke
;; breaks the local call too, no second-class behavior on the hosting side.
(define (^ping bcom) (methods [(ping) 99]))
(define (^doubler bcom) (methods [(double n) (* n 2)]))

(define lc-server (listen "127.0.0.1" 0))
(define lc-ready (make-semaphore 0))
(define lc-ch (make-channel))
(define lc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put lc-ch e))])
       (define hconn (accept lc-server))
       (conn-publish hconn "tool" ^ping)
       (semaphore-post lc-ready)
       (conn-serve hconn)
       (channel-put lc-ch 'served)))))

(define lc-conn (connect (tcp-locator "127.0.0.1" (server-port lc-server))))
(semaphore-wait lc-ready)

;; A caretaker over a local tool, called locally by its own host.
(define lc-local (conn-spawn lc-conn ^doubler))
(define lc-care (conn-caretaker lc-conn lc-local))
(expect (= 42 (conn-send lc-conn lc-care 'double 21))
        "local-call: a local proxy answers a local call")

;; A caretaker over a far tool, called locally: the proxy forwards across the wire
;; and the local send still settles on the partner's reply.
(define lc-far (conn-fetch lc-conn "tool"))
(define lc-care-far (conn-caretaker lc-conn lc-far))
(expect (= 99 (conn-send lc-conn lc-care-far 'ping))
        "local-call: a local call over a far tool settles")

;; Revoke severs the local call exactly as it severs a partner's.
(conn-revoke! lc-conn lc-care)
(define lc-severed
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (conn-send lc-conn lc-care 'double 1) #f))
(expect (and (exn:fail:pancake? lc-severed)
             (regexp-match? #rx"Revoked" (exn-message lc-severed)))
        "local-call: revoke breaks a local call too")

(connection-close! lc-conn)
(define lc-host-result (channel-get lc-ch))
(when (exn? lc-host-result) (raise lc-host-result))
(server-close! lc-server)

(printf "racket zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)\n")

;; ── À-la-carte transports: one round-trip over each composable transport module ─
;; The core peer is sans-io; each transport archive ships as its own composable
;; module (`pancake-tcp.rkt`, `pancake-inproc.rkt`), built on the core's frame
;; shuttle. These two sections drive the *same* counter round-trip over each
;; explicit netlayer's whole-frame endpoints, proving a Racket consumer composes
;; the core with a transport à la carte exactly as a C consumer links the
;; archives. Each side owns a raw-open peer; only the transport's (read, write)
;; pair differs, so the driving logic is shared.
;;
;; The exchange is single-threaded on purpose. Unlike Racket's own
;; scheduler-aware ports, these explicit C-ABI netlayers park the whole Racket
;; place for the duration of a foreign read or write, so two peers cannot
;; rendezvous across green threads in one place. The dialer queues without a
;; concurrent accept, so the dogfood writes the call, accepts, serves, replies,
;; and reads the resolution in sequence over buffered endpoints.
(define (transport-counter-roundtrip client-read client-write! server-read server-write!)
  ;; Client: import the partner's export 7 and queue counter.add(5) with answer 9.
  (define cpeer (make-peer/raw-open))
  (peer-register-import! cpeer 7)
  (peer-send-deliver! cpeer (far 7) (list (sym "add") 5) #:answer 9)
  (peer-step! cpeer)
  (client-write! (peer-take-outbound cpeer))
  ;; Server: host export 7, read the deliver, and reply with the sum.
  (define speer (make-peer/raw-open))
  (peer-register-export! speer 7)
  (peer-feed! speer (server-read))
  (define dev (peer-poll speer))
  (expect (deliver-event? dev) "transport: host received a deliver")
  (peer-send-resolve! speer (deliver-event-answer dev) (fulfill (+ 10 (cadr (deliver-event-args dev)))))
  (peer-step! speer)
  (server-write! (peer-take-outbound speer))
  ;; Client: read the resolution and report the settled total.
  (peer-feed! cpeer (client-read))
  (define rev (peer-poll cpeer))
  (and (resolve-event? rev) (= 9 (resolve-event-answer rev))
       (fulfill? (resolve-event-resolution rev))
       (fulfill-value (resolve-event-resolution rev))))

;; libpancake_net_transport_inproc: the socket-free netlayer. A listener binds a
;; string designator; a dialer names it. No kernel transport, no file descriptors.
(define inproc-nl (make-inproc-netlayer))
(define inproc-lst (inproc-netlayer-listen inproc-nl "smoke-rendezvous"))
(define inproc-client (inproc-netlayer-connect inproc-nl "smoke-rendezvous"))
(define inproc-server (inproc-listener-accept inproc-lst))
(define inproc-total
  (transport-counter-roundtrip
   (lambda () (inproc-endpoint-read-frame inproc-client))
   (lambda (f) (inproc-endpoint-write-frame! inproc-client f))
   (lambda () (inproc-endpoint-read-frame inproc-server))
   (lambda (f) (inproc-endpoint-write-frame! inproc-server f))))
(expect (equal? 15 inproc-total) "inproc: counter.add(5) round-tripped to 15 over the socket-free netlayer")
(inproc-endpoint-close! inproc-client)
(inproc-endpoint-close! inproc-server)
(inproc-listener-close! inproc-lst)
(inproc-netlayer-release! inproc-nl)

(printf "racket zig-smoke OK: drove OCapN over the socket-free in-process netlayer\n")

;; libpancake_net_transport_tcp: the explicit C-ABI TCP netlayer (cleartext,
;; loopback-grade). Same round-trip over real sockets, proving the tcp module
;; composes with the core just as inproc does, a different archive, one core.
(define tcp-nl (make-netlayer))
(define tcp-lst (netlayer-listen tcp-nl "127.0.0.1" 0))
(define tcp-port (listener-port tcp-lst))
(define tcp-client (netlayer-connect tcp-nl "127.0.0.1" tcp-port))
(define tcp-server (listener-accept tcp-lst))
(define tcp-total
  (transport-counter-roundtrip
   (lambda () (endpoint-read-frame tcp-client))
   (lambda (f) (endpoint-write-frame! tcp-client f))
   (lambda () (endpoint-read-frame tcp-server))
   (lambda (f) (endpoint-write-frame! tcp-server f))))
(expect (equal? 15 tcp-total) "tcp netlayer: counter.add(5) round-tripped to 15 over the C-ABI TCP transport")
(endpoint-close! tcp-client)
(endpoint-close! tcp-server)
(listener-close! tcp-lst)
(netlayer-release! tcp-nl)

(printf "racket zig-smoke OK: drove OCapN over the C-ABI TCP netlayer\n")
