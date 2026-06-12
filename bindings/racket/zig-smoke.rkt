#lang racket/base
;; Racket dogfood of the Zig libpancake C ABI, through the idiomatic `pancake.rkt`
;; module: drive OCapN with native Racket values and event structs — no FFI in
;; sight. This is the consumer `zig build bindings` runs.

(require "pancake.rkt"
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

(printf "racket zig-smoke OK: Goblins-idiom actor — spawn, $, <-, on, bcom\n")

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
;; `(<- (far 7) 'add 5)` through the seam — no hand-built wire message. Shuttle
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
;; fetches `svc`, calls it, and reads the reply off the far vow — a keyed
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
(define hl-conn (connect "127.0.0.1" (server-port hl-server)))
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
;; export, so a wire route would never reply — mirroring Rust's
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

(define cp-conn (connect "127.0.0.1" (server-port cp-server)))
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
