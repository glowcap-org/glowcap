#lang racket/base
;; Racket dogfood of the Zig libpancake C ABI, through the idiomatic `pancake.rkt`
;; module: drive OCapN with native Racket values and event structs — no FFI in
;; sight. This is the consumer `zig build bindings` runs.

(require "pancake.rkt"
         ffi/unsafe
         racket/tcp)

(define (fail msg) (eprintf "racket zig-smoke FAILED: ~a\n" msg) (exit 1))
(define (expect cond msg) (unless cond (fail msg)))

;; The linked library reports a real ABI version.
(let-values ([(major minor patch) (abi-version)])
  (expect (positive? (+ major minor patch)) "abi-version is nonzero"))

;; Construct a call with native args, then read it back as a typed event.
(define caller (make-peer))
(peer-register-import! caller 5)
(peer-send-deliver! caller (far 5) (list 42 #"hi") #:answer 9)
(peer-step! caller)
(define wire (peer-take-outbound caller))
(expect (and wire (regexp-match? #rx#"^<10'op:deliver" wire)) "constructed a real op:deliver")
(peer-release! caller)

(define callee (make-peer))
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
(define owned-callee (make-peer/in ctx))
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
(define peer (make-peer))
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
;; with answer 11 (where `3'add` is the OCapN symbol "add"), serve the polled
;; event into the vat, step, and assert the outbound `op:resolve` fulfils 15.
(define host-peer (make-peer))
(define host-vat (make-vat #:peer host-peer))
(with-vat host-vat
  (publish! host-vat (spawn ^counter 10) 7))
(peer-feed! host-peer #"<10'op:deliver<11'desc:export7+>[3'add5+]11+f>")
(define host-ev (peer-poll host-peer))
(expect (deliver-event? host-ev) "host: got a deliver event")
(expect (vat-serve! host-vat host-ev) "host: vat served the deliver")
(peer-step! host-peer)
(define host-wire (peer-take-outbound host-peer))
(expect (and host-wire (regexp-match? #rx#"op:resolve" host-wire)) "host: replied with op:resolve")
(expect (and host-wire (regexp-match? #rx#"15\\+" host-wire)) "host: counter.add(5) fulfilled with 15")
(peer-release! host-peer)

(printf "racket zig-smoke OK: hosted a Goblins actor on an OCapN export\n")

;; ── The local|far seam: a vat far-send round-trip ────────────────────────────
;; peerB's vat publishes a counter at export 7; peerA's vat far-sends
;; `(<- (far 7) 'add 5)` through the seam — no hand-built wire message. Shuttle
;; A's outbound deliver to B and serve it (10 -> 15, resolves), shuttle the
;; resolve back, and serve it on A to fire the far vow. This is the same
;; location-transparent round-trip the Rust, Python, and Deno smokes prove.
(define fa-peer (make-peer))
(define fb-peer (make-peer))
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

;; B's `op:resolve` goes back to A; serving it fires the far vow's listener.
(peer-step! fb-peer)
(define fb-wire (peer-take-outbound fb-peer))
(expect (and fb-wire (regexp-match? #rx#"op:resolve" fb-wire)) "far: B produced an outbound resolve")
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
(define dc-peer (make-peer))
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
(define-values (_lh server-port _rh _rp) (tcp-addresses listener #t))
(define result-ch (make-channel))

(define server
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put result-ch e))])
       (define-values (sin sout) (tcp-accept listener))
       (define speer (make-peer))
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

(define client-conn (async-connect "127.0.0.1" server-port))
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
