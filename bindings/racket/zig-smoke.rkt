#lang racket/base
;; Racket dogfood of the Zig pancake C ABI archives, through the idiomatic
;; composable modules — the CapTP session surface in `pancake.rkt` plus one
;; module per transport archive (`pancake-tcp.rkt`, `pancake-inproc.rkt`),
;; composed à la carte exactly as a C consumer links the archives. Everything
;; rides the byte-fed host archive (libpancake_driver, ADR-0072 / ADR-0079)
;; with native Racket values — no FFI in sight for an application; the
;; plumbing sections below reach the binding's own `private/` modules to
;; script wire faults and to shuttle host frames over the C transport
;; endpoints, which is dogfood work, not application surface. This is the
;; consumer `zig build bindings` runs.

(require "pancake.rkt"
         "pancake-tcp.rkt"
         "pancake-inproc.rkt"
         ;; Binding-internal plumbing, for the scripted sections only: the
         ;; byte-fed session constructors and pump pieces, the host FFI's
         ;; open/fetch verbs, the local vat half (`bind-export!` / `vat-resolve-target`),
         ;; and the shared cstruct vocabulary.
         "private/session.rkt"
         "private/listen.rkt"
         "private/host.rkt"
         "private/async.rkt"
         "private/pump.rkt"
         "private/action.rkt"
         "private/promise.rkt"
         "private/gc.rkt"
         "private/vat.rkt"
         "private/ffi-driver.rkt"
         "private/ffi-shared.rkt"
         "private/errors.rkt"
         "private/codec.rkt"
         racket/tcp)

;; Line-buffer the OK lines so a failure can never swallow the progress that
;; preceded it.
(file-stream-buffer-mode (current-output-port) 'line)

(define (fail msg) (eprintf "racket zig-smoke FAILED: ~a\n" msg) (exit 1))
(define (expect cond msg) (unless cond (fail msg)))

;; The linked library reports a real ABI version.
(let-values ([(major minor patch) (abi-version)])
  (expect (positive? (+ major minor patch)) "abi-version is nonzero"))

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

;; ── The local export table: bind-export! + vat-resolve-target ─────────────────
;; Hosting a behavior for a partner is the connection's job (`session-spawn` /
;; `session-publish`). The vat still records which export id names which local
;; actor so a near reference resolves in-process (`vat-resolve-target`) instead
;; of going out on the wire to its own export — the same self-routing the
;; sibling bindings perform through their hosted tables.
(define lv (make-vat))
(define lv-counter (with-vat lv (spawn ^counter 10)))
(bind-export! lv lv-counter 7)
(expect (equal? (vat-resolve-target lv (near 7)) lv-counter)
        "local export: vat-resolve-target maps a bound near-ref to its actor")
(expect (equal? (vat-resolve-target lv (near 99)) (near 99))
        "local export: an unbound near-ref comes back unchanged")
(with-vat lv
  (expect (= 15 ($ lv-counter 'add 5)) "local export: the bound actor still near-calls"))

(printf "racket zig-smoke OK: bind-export! + vat-resolve-target self-route a near-ref\n")

;; ── The local|far seam: `<-` and `on` across a live session ────────────────
;; A host publishes a counter; the client reaches it through the vat verbs —
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
(define fs-session (connect (tcp-locator "127.0.0.1" (server-port fs-server))))
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
(define dc-session (connect (tcp-locator "127.0.0.1" (server-port dc-server))))
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
;; green thread that is NOT the connection's pumping thread — a server pushing
;; a broadcast to a subscriber parked reading — must call `session-flush!` to put
;; the bytes on the wire now. The client's inbox capability travels to the
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
                         ;; tells it and flushes — the cross-thread send seam.
                         (thread
                          (lambda ()
                            (define c (unbox xf-session-box))
                            (session-tell c cap 'note "broadcast")
                            (session-flush! c)))
                         "registered"])))
       (semaphore-post xf-ready)
       (session-serve hsession)))))
(define xf-session (connect (tcp-locator "127.0.0.1" (server-port xf-server))))
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
    (with-handlers ([exn:fail:pancake? void])
      (session-send xf-session xf-registry 'register xf-inbox))
    (loop (add1 i))))
(expect (member "broadcast" (unbox xf-notes))
        "cross-thread: session-flush! put the other thread's tell on the wire")
(session-close! xf-session)
(void (sync/timeout 2 (thread-dead-evt xf-host)))
(server-close! xf-server)

(printf "racket zig-smoke OK: a cross-thread tell reaches the wire through session-flush!\n")

;; ── Hosting: high-level listen/accept against connect ─────────────────────────
;; A host thread listens on an ephemeral port, accepts one partner on the
;; high-level surface, publishes `svc`, and serves. The main thread `connect`s,
;; fetches `svc`, and calls it — a keyed op:start-session handshake on both
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
(define hl-session (connect (tcp-locator "127.0.0.1" (server-port hl-server))))
(semaphore-wait hl-ready)
(define hl-svc (session-fetch hl-session "svc"))
(expect (equal? "hello pancake" (session-send hl-session hl-svc 'greet "pancake"))
        "listen/accept: high-level call round-tripped")
(session-close! hl-session)
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
       (define hsession (accept en-server))
       (session-publish hsession "greeter"
                     (lambda (bcom)
                       (methods
                        [(hello) (sym "alive")])))
       (semaphore-post en-ready)
       (session-serve hsession)
       (channel-put en-ch 'served)))))

(define en-session (connect (tcp-locator "127.0.0.1" (server-port en-server))))
(semaphore-wait en-ready)
;; The connection is already open; enliven keys on the sturdyref's swissnum,
;; carried by the URI as `/s/greeter`.
(define en-sturdyref "ocapn://greeter-host.tcp/s/greeter")
(define en-cap (session-enliven en-session en-sturdyref))
(expect (far-ref? en-cap) "enliven: a sturdyref enlivened to a far capability")
(expect (equal? (sym "alive") (session-send en-session en-cap 'hello)) "enliven: the live capability answers hello")
;; A repeat enliven hits the dedup cache: the same live reference, no wire fetch.
(define en-again (session-enliven en-session en-sturdyref))
(expect (equal? en-again en-cap) "enliven: a repeat enliven hits the cache")
(expect (equal? (sym "alive") (session-send en-session en-again 'hello)) "enliven: the cached capability answers hello")
(session-close! en-session)
(define en-host-result (channel-get en-ch))
(when (exn? en-host-result) (raise en-host-result))
(expect (eq? 'served en-host-result) "enliven: host served to a clean close")
(server-close! en-server)

(printf "racket zig-smoke OK: a sturdyref enlivens to a live capability, and a repeat enliven hits the cache\n")

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
                        [(echo big k bs) (list big k bs)])))
       (semaphore-post cx-ready)
       (session-serve hsession)
       (channel-put cx-ch 'served)))))
(define cx-session (connect (tcp-locator "127.0.0.1" (server-port cx-server)) #:codec 'capnp))
(semaphore-wait cx-ready)
(define cx-svc (session-fetch cx-session "board"))
(define cx-big (expt 2 80))
(expect (equal? (list cx-big (kw "prio") #"hi")
                (session-send cx-session cx-svc 'echo cx-big (kw "prio") #"hi"))
        "capnp: big-integer + keyword + bytes args round-trip a Cap'n Proto session")
(session-close! cx-session)
(define cx-host-result (channel-get cx-ch))
(when (exn? cx-host-result) (raise cx-host-result))
(expect (eq? 'served cx-host-result) "capnp: host served to a clean close")
(server-close! cx-server)

(printf "racket zig-smoke OK: a capnp session opens through #:codec and big-integer + keyword args round-trip\n")

;; ── A byte-sniffing TCP relay ─────────────────────────────────────────────────
;; A relay between a dialing client and `target-port` that watches every
;; client→server chunk with `on-chunk`: return 'close to drop both sides on the
;; spot (a scripted network fault), anything else to forward. Both endpoints
;; stay fully high-level; the relay is how the dogfood observes — or severs —
;; the wire between them without a raw peer.
(define (start-sniffing-relay target-port on-chunk)
  (define lst (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_h port _rh _rp) (tcp-addresses lst #t))
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define-values (cin cout) (tcp-accept lst))
       (define-values (sin sout) (tcp-connect "127.0.0.1" target-port))
       (define (close-all!)
         (for-each (lambda (p) (with-handlers ([(lambda (_) #t) void])
                                 (if (input-port? p) (close-input-port p) (close-output-port p))))
                   (list cout sout cin sin)))
       (define (pump-side in out watch)
         (thread
          (lambda ()
           (with-handlers ([(lambda (_) #t) void])
             (let loop ()
               (define buf (make-bytes 65536))
               (define n (read-bytes-avail! buf in))
               (cond
                 [(eof-object? n) (close-all!)]
                 [else
                  (define chunk (subbytes buf 0 n))
                  (cond
                    [(and watch (eq? 'close (watch chunk))) (close-all!)]
                    [else (write-bytes chunk out) (flush-output out) (loop)])]))))))
       (pump-side cin sout on-chunk)
       (pump-side sin cout #f))))
  (values lst port))

;; ── Distributed GC (ADR-0063): a dropped fetched import releases its export ──
;; Opt the client into GC; once on, a far capability returned by `session-fetch`
;; releases its import — one `op:gc-export` — when the collector reclaims the
;; last reference to it. Both ends are fully high-level; the release is
;; asserted on the wire itself, through a sniffing relay between them (the
;; partner's engine consumes `op:gc-export` internally, so only the bytes in
;; flight prove it shipped). The client fetches a cap inside a thunk so it
;; falls out of scope, drops it, and forces collection; the finalizer parks the
;; release, and the next `session-fetch` drains it to the wire where the relay
;; sees it.
(define gc-server (listen "127.0.0.1" 0))
(define gc-ready (make-semaphore 0))
(define gc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept gc-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(ping) (sym "alive")])))
       (semaphore-post gc-ready)
       (session-serve hsession)))))
(define gc-saw (box #f))
(define-values (gc-relay gc-relay-port)
  (start-sniffing-relay (server-port gc-server)
                        (lambda (chunk)
                          (when (regexp-match? #rx#"op:gc-export" chunk) (set-box! gc-saw #t))
                          #f)))
(define gc-session (session-with-gc! (connect (tcp-locator "127.0.0.1" gc-relay-port))))
(semaphore-wait gc-ready)
;; Fetch and drop inside a thunk so the capability falls out of scope (a
;; module-level binding would root it forever and never finalize).
(define (gc-fetch-and-drop!)
  (define cap (session-fetch gc-session "svc"))
  (expect (far-ref? cap) "gc: fetched a far import")
  (void))
(gc-fetch-and-drop!)
;; Force collection, then re-fetch to drain the parked release, until the relay
;; sees the gc-export on the wire (or we exhaust the budget).
(let loop ([i 0])
  (collect-garbage)
  (sleep 0.02)
  (session-fetch gc-session "svc")
  (unless (or (unbox gc-saw) (>= i 100)) (loop (add1 i))))
(expect (unbox gc-saw) "gc: the wire carried op:gc-export for the dropped fetched import")
(session-close! gc-session)
(void (sync/timeout 2 (thread-dead-evt gc-host)))
(tcp-close gc-relay)
(server-close! gc-server)

(printf "racket zig-smoke OK: a dropped fetched import releases its export when GC is opted in\n")

;; ── Byte-fed connections: minting a host connection over any transport ────────
;; The host archive is byte-fed (ADR-0072), so a connection needs no socket:
;; these two constructors open the dialing / accepting half over an arbitrary
;; `async-transport`, the same seam the iroh companion uses. The scripted
;; sections below use them to inject hostile bytes directly and to shuttle host
;; frames over the C transport endpoints.
(define (open-dialed-over m transport-name designator tr)
  ;; Mint only — the smoke drives both hellos by hand before finish-establish!.
  (define tb (string->bytes/utf-8 transport-name))
  (define db (string->bytes/utf-8 designator))
  (call-with-host m
    (lambda ()
      (define-values (rc ptr)
        (pancake_host_session_open_dialed_locator
         (host-ptr m)
         (pin-immobile tb) (bytes-length tb)
         (pin-immobile db) (bytes-length db)))
      (check/host rc)
      (build-session m ptr tr #f))))

(define (open-accepted-over m transport-name designator tr)
  (define tb (string->bytes/utf-8 transport-name))
  (define db (string->bytes/utf-8 designator))
  (define hb #"")
  (call-with-host m
    (lambda ()
      (define-values (rc ptr)
        (pancake_host_session_open_accepted (host-ptr m)
                                         (pin-immobile tb) (bytes-length tb)
                                         (pin-immobile db) (bytes-length db)
                                         (pin-immobile hb) (bytes-length hb)))
      (check/host rc)
      (build-session m ptr tr #f))))

;; ── Bounded inbox: an over-cap frame is a typed refusal, not "read more" ──────
;; A connection's inbox keeps growing only while the core's stream delimiter
;; (`pancake_host_session_feed_bytes`) reports an unconsumed tail; a frame
;; declaring more than the frame cap must surface as the typed FRAME_TOO_LARGE
;; error (-11), or a hostile partner could grow the inbox without bound. This
;; feeds the hostile prefix through the exact byte path the connection pump
;; uses, into a byte-fed connection whose transport discards the projected
;; outbound abort.
(define oc-host (make-fresh-host))
(define oc-session (open-accepted-over oc-host "tcp" (socket-addr-designator "127.0.0.1" 9)
                                    (async-transport (lambda (_f) (void)) void
                                                     (lambda (_wake) eof) void)))
(drain-host! oc-host) ; the signed op:start-session leaves into the discard transport
(define oc-code
  (with-handlers ([exn:fail:pancake? (lambda (e) (exn:fail:pancake-code e))])
    (feed-bytes! oc-session #"<10'op:deliver<11'desc:export7+>[2000000:")
    'no-error))
(expect (equal? -11 oc-code) "over-cap frame: typed FRAME_TOO_LARGE refusal")
(session-close! oc-session)

(printf "racket zig-smoke OK: an over-cap frame refuses typed instead of buffering\n")

;; ── last-abort: a refused frame carries its typed cause ───────────────────────
;; The flat return code names the failure family; the `abort` field on the exn
;; a feeding connection raises names the member: domain, projected op:abort
;; kind, and the originating error. The hostile bytes are fed straight into a
;; byte-fed connection through the core's stream delimiter, whose transport
;; discards the projected outbound abort.
(define la-host (make-fresh-host))
(define la-session (open-accepted-over la-host "tcp" (socket-addr-designator "127.0.0.1" 9)
                                    (async-transport (lambda (_f) (void)) void
                                                     (lambda (_wake) eof) void)))
(drain-host! la-host) ; the signed op:start-session leaves into the discard transport
(expect (not (session-last-abort la-session)) "last-abort: nothing recorded before a failure")
(define la-exn
  (with-handlers ([exn:fail:pancake? values])
    (feed-bytes! la-session #"this is not a frame")
    'no-error))
(expect (exn:fail:pancake? la-exn) "last-abort: a refused frame raised exn:fail:pancake")
(define la-info (exn:fail:pancake-abort la-exn))
(expect (abort-info? la-info) "last-abort: the exn carries the typed abort detail")
(expect (eq? 'codec (abort-info-domain la-info)) "last-abort: domain is codec")
(expect (equal? "MalformedFrame" (abort-info-kind la-info)) "last-abort: kind is MalformedFrame")
(expect (equal? "MalformedFrame" (abort-info-error-name la-info)) "last-abort: error-name is MalformedFrame")
(expect (abort-info? (session-last-abort la-session)) "last-abort: the reader reads the same recorded cause")
(session-close! la-session)

(printf "racket zig-smoke OK: a refused frame carries its typed last-abort cause\n")

;; ── Session parity: self-spawned sends resolve in process; failures are typed ─
;; A host publishes `svc` (whose `boom` method raises) and serves. The client
;; proves three contracts the other bindings already pin: a send/tell to a Ref
;; this same session spawned resolves in process (the server hosts no such
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
       (define hsession (accept cp-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(boom) (error 'svc "deliberate failure")])))
       (semaphore-post cp-ready)
       (session-serve hsession)
       (channel-put cp-ch 'served)))))

(define cp-session (connect (tcp-locator "127.0.0.1" (server-port cp-server))))
(semaphore-wait cp-ready)

;; Self-spawned send and tell: the client never runs a serve loop, so only an
;; in-process turn can settle these.
(define cp-me (session-spawn cp-session ^counter 10))
(expect (near-ref? cp-me) "self-spawn: session-spawn returns a near capability")
(expect (= 15 (session-send cp-session cp-me 'add 5)) "self-spawn: session-send resolved in process")
(session-tell cp-session cp-me 'add 100)
(expect (= 115 (session-send cp-session cp-me 'get)) "self-spawn: session-tell ran the local turn")

;; A partner break is a typed pancake failure carrying PANCAKE_ERR_BROKEN (-14).
(define cp-svc (session-fetch cp-session "svc"))
(define cp-broken
  (with-handlers ([exn:fail:pancake? values])
    (session-send cp-session cp-svc 'boom)
    'no-error))
(expect (exn:fail:pancake? cp-broken) "break: session-send raised exn:fail:pancake")
(expect (equal? -14 (exn:fail:pancake-code cp-broken)) "break: code is PANCAKE_ERR_BROKEN")
(expect (regexp-match? #rx"deliberate failure" (exn-message cp-broken))
        "break: the partner's own diagnostic crossed the wire")

;; A fetch of an unpublished name breaks too, and session-fetch re-raises the typed
;; failure untouched instead of flattening it to a generic exn:fail.
(define cp-missing
  (with-handlers ([exn:fail:pancake? values])
    (session-fetch cp-session "no-such-name")
    'no-error))
(expect (exn:fail:pancake? cp-missing) "fetch: an unknown name raised exn:fail:pancake")
(expect (equal? -14 (exn:fail:pancake-code cp-missing)) "fetch: code is PANCAKE_ERR_BROKEN")

(session-close! cp-session)
(define cp-host-result (channel-get cp-ch))
(when (exn? cp-host-result) (raise cp-host-result))
(expect (eq? 'served cp-host-result) "connection parity: host served to a clean close")
(server-close! cp-server)

(printf "racket zig-smoke OK: self-spawned sends resolve in process and failures are typed\n")

;; ── Foreign argument: a capability from another connection fails closed ───────
;; A capability fetched on one connection cannot ride another connection's send
;; as an argument — the host refuses the send whole (typed INVALID_ARGUMENT)
;; rather than mis-encode a reference the partner never imported — and the
;; refusal walks containers, so hiding the foreign capability inside a list
;; changes nothing. Two listens give two partner designators so one client host
;; can hold both sessions (a second dial to the same address refuses
;; SessionPairExists).
(define fa-server-1 (listen "127.0.0.1" 0))
(define fa-server-2 (listen "127.0.0.1" 0))
(define fa-ready-1 (make-semaphore 0))
(define fa-ready-2 (make-semaphore 0))
(define (fa-serve! server ready)
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(echo x) x])))
       (semaphore-post ready)
       (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))))
(void (fa-serve! fa-server-1 fa-ready-1))
(void (fa-serve! fa-server-2 fa-ready-2))
(define fa-session-1 (connect (tcp-locator "127.0.0.1" (server-port fa-server-1))))
(semaphore-wait fa-ready-1)
(define fa-session-2 (connect (tcp-locator "127.0.0.1" (server-port fa-server-2))
                           #:host (session-host fa-session-1)))
(semaphore-wait fa-ready-2)
(define fa-cap-1 (session-fetch fa-session-1 "svc"))
(define fa-cap-2 (session-fetch fa-session-2 "svc"))
(define fa-refused
  (with-handlers ([exn:fail:pancake? values])
    (session-send fa-session-2 fa-cap-2 'echo (list 1 fa-cap-1 2))
    'no-error))
(expect (exn:fail:pancake? fa-refused) "foreign arg: the cross-connection send was refused")
(expect (equal? -3 (exn:fail:pancake-code fa-refused)) "foreign arg: code is PANCAKE_ERR_INVALID_ARGUMENT")
(session-close! fa-session-1)
(session-close! fa-session-2)
(server-close! fa-server-1)
(server-close! fa-server-2)

(printf "racket zig-smoke OK: a foreign capability in argument position fails closed, containers included\n")

;; ── Promise pipelining: the questioner's half (ADR-0007) ──────────────────────
;; `session-send-promise` returns a far vow that is itself a `send` target, so
;; a create -> assign -> complete -> status chain is issued against the
;; *unresolved* create answer and the four delivers travel as one batch on the
;; settling `session-send`'s pump. The board's `create` spawns a fresh task
;; mid-turn and returns it; the partner's engine queues the pipelined calls on
;; that pending answer and drains them onto the task once create resolves. A
;; status of `done` proves the chain crossed the wire without round-tripping
;; per link.
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
       (define hsession (accept pl-server))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(create name) (session-spawn hsession ^task)])))
       (semaphore-post pl-ready)
       (session-serve hsession)
       (channel-put pl-ch 'served)))))

(define pl-session (connect (tcp-locator "127.0.0.1" (server-port pl-server))))
(semaphore-wait pl-ready)
(define pl-root (session-fetch pl-session "root"))
;; The four verbs leave together: none waits for create's reply, and assign /
;; complete / status target the create answer directly.
(define pl-task (session-send-promise pl-session pl-root 'create "benchmark"))
(void (session-send-promise pl-session pl-task 'assign "alice"))
(void (session-send-promise pl-session pl-task 'complete))
(define pl-status (session-send pl-session pl-task 'status))
(expect (equal? "done" pl-status) "pipelining: the chained status settled to done")

(session-close! pl-session)
(define pl-host-result (channel-get pl-ch))
(when (exn? pl-host-result) (raise pl-host-result))
(expect (eq? 'served pl-host-result) "pipelining: host served to a clean close")
(server-close! pl-server)

(printf "racket zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch\n")

;; ── Pipelined projections (ADR-0050/ADR-0052) ─────────────────────────────────
;; `session-untag`/`session-index` project a tag/element out of a far
;; vow *before it settles*, each returning a new pipelinable vow. The board's
;; `make` returns a `("assigned" label 7)` row wrapped in a "task" tag; `untag`
;; unwraps the single-value tag to that row and `index 1` takes the label, a
;; two-hop chain riding the unresolved `make` answer, no extra round trip. The
;; source vow is then awaited to prove a far reply that landed *before* its
;; listener (while a sibling projection pumped the loop) still settles from the
;; vow's recorded state. (`get` projects a Struct, which the Racket value model
;; surfaces as a tagged/struct arg; index and untag are the
;; cross-binding-comparable pair, so they are what this dogfood asserts,
;; matching Python.)
(define pj-server (listen "127.0.0.1" 0))
(define pj-ready (make-semaphore 0))
(define pj-ch (make-channel))
(define pj-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pj-ch e))])
       (define hsession (accept pj-server))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(make label) (tagged-arg "task" (list (list "assigned" label 7)))])))
       (semaphore-post pj-ready)
       (session-serve hsession)
       (channel-put pj-ch 'served)))))

(define pj-session (connect (tcp-locator "127.0.0.1" (server-port pj-server))))
(semaphore-wait pj-ready)
(define pj-root (session-fetch pj-session "root"))
;; Neither projection waits for make's reply: they ride the unresolved make
;; answer and the whole chain leaves on one pump.
(define pj-made (session-send-promise pj-session pj-root 'make "alice"))
(define pj-label (session-await pj-session (session-index pj-session (session-untag pj-session pj-made "task") 1)))
(expect (equal? "alice" pj-label) "projections: pipelined untag->index reached the label")
;; The source answer settled while the projection pumped the loop; awaiting it
;; now must still resolve from the vow's recorded state.
(define pj-full (session-await pj-session pj-made))
(expect (and (tagged-arg? pj-full) (equal? "task" (tagged-arg-tag pj-full)))
        "projections: the late source await still settled to the tagged row")

(session-close! pj-session)
(define pj-host-result (channel-get pj-ch))
(when (exn? pj-host-result) (raise pj-host-result))
(expect (eq? 'served pj-host-result) "projections: host served to a clean close")
(server-close! pj-server)

(printf "racket zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles\n")

;; ── Unawaited break + a real disconnect ───────────────────────────────────────
;; Two failure contracts over a real socket. First: an unawaited
;; `session-send-promise` whose reply breaks stays silent — no listener means the
;; broken vow crashes nothing, and the connection keeps answering. Second: a
;; partner that hangs up mid-question settles the pending `session-send` with a
;; typed PANCAKE_ERR_CLOSED failure instead of hanging it forever.
(define ub-server (listen "127.0.0.1" 0))
(define ub-ready (make-semaphore 0))
(define ub-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept ub-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(boom) (error "kaboom: refused")]
                        [(ok) (sym "fine")])))
       (semaphore-post ub-ready)
       (session-serve hsession)))))
(define ub-session (connect (tcp-locator "127.0.0.1" (server-port ub-server))))
(semaphore-wait ub-ready)
(define ub-cap (session-fetch ub-session "svc"))
;; Fire the failing verb and never await it; the break arrives while the next
;; call pumps and must stay silent.
(void (session-send-promise ub-session ub-cap 'boom))
(expect (equal? (sym "fine") (session-send ub-session ub-cap 'ok))
        "unawaited: a later call still settles after an unawaited break")
(session-close! ub-session)
(server-close! ub-server)

;; Real disconnect: both ends are high-level; a sniffing relay between them
;; drops the wire the moment the `hang` deliver crosses it, so the client's
;; question is pending when the transport dies and can never be answered.
(define dcs-server (listen "127.0.0.1" 0))
(define dcs-ready (make-semaphore 0))
(define dcs-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept dcs-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(hang) (sym "never")])))
       (semaphore-post dcs-ready)
       (session-serve hsession)))))
(define-values (dcs-relay dcs-relay-port)
  (start-sniffing-relay (server-port dcs-server)
                        (lambda (chunk) (if (regexp-match? #rx#"hang" chunk) 'close #f))))
(define dcs-session (connect (tcp-locator "127.0.0.1" dcs-relay-port)))
(semaphore-wait dcs-ready)
(define dcs-cap (session-fetch dcs-session "svc"))
(define dcs-err
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send dcs-session dcs-cap 'hang)
    #f))
(expect (and dcs-err (= -8 (exn:fail:pancake-code dcs-err))) ; PANCAKE_ERR_CLOSED
        "disconnect: the pending send failed typed ERR-CLOSED, never hung")
(session-close! dcs-session)
(void (sync/timeout 2 (thread-dead-evt dcs-host)))
(tcp-close dcs-relay)
(server-close! dcs-server)

(printf "racket zig-smoke OK: an unawaited break stays silent, and a real disconnect fails a pending send typed\n")

;; ── A rude probe cannot close the listener ────────────────────────────────────
;; A rude TCP probe — connect, say nothing, hang up — is that connection's
;; failure, not the listener's. `accept` completes the keyed handshake, so the
;; probe makes that one accept raise; the host catches it and keeps accepting,
;; and the next, real client is served. Without that isolation one port scan
;; takes a long-lived server down.
(define rp-server (listen "127.0.0.1" 0))
(define rp-ready (make-semaphore 0))
(define rp-host
  (thread
   (lambda ()
     (let accept-loop ()
       (define hsession
         (with-handlers ([(lambda (_) #t) (lambda (_e) #f)])
           (accept rp-server)))
       (cond
         [hsession
          (session-publish hsession "svc" (lambda (bcom) (methods [(ping) (sym "alive")])))
          (semaphore-post rp-ready)
          (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
            (session-serve hsession))]
         [else (accept-loop)])))))
;; The probe: open a socket and immediately hang up.
(define-values (rp-in rp-out) (tcp-connect "127.0.0.1" (server-port rp-server)))
(close-output-port rp-out)
(close-input-port rp-in)
(define rp-session (connect (tcp-locator "127.0.0.1" (server-port rp-server))))
(semaphore-wait rp-ready)
(define rp-cap (session-fetch rp-session "svc"))
(expect (equal? (sym "alive") (session-send rp-session rp-cap 'ping))
        "probe: the listener survived the rude probe and served the next client")
(session-close! rp-session)
(server-close! rp-server)

(printf "racket zig-smoke OK: a rude probe cannot close the listener\n")

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
       (define hsession (accept mb-server))
       ;; The caretaker the host hands out, stashed so `revoke` can sever it.
       (define proxy-box (box #f))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(make-proxy tool)
                         (define proxy (session-caretaker hsession tool))
                         (set-box! proxy-box proxy)
                         proxy]
                        [(make-readonly tool) (session-attenuate hsession tool '("get"))]
                        [(revoke) (session-revoke! hsession (unbox proxy-box)) "revoked"])))
       (semaphore-post mb-ready)
       (session-serve hsession)
       (channel-put mb-ch 'served)))))

(define mb-session (connect (tcp-locator "127.0.0.1" (server-port mb-server))))
(semaphore-wait mb-ready)
(define mb-tool (session-spawn mb-session ^tool))
(define mb-root (session-fetch mb-session "root"))

;; Live caretaker: a call forwards across the host to the client's far tool.
(define mb-proxy (session-send mb-session mb-root 'make-proxy mb-tool))
(expect mb-proxy "proxy: the host returned a caretaker proxy")
(expect (= 42 (session-send mb-session mb-proxy 'add 41)) "proxy: caretaker forwards to the far tool")

;; Attenuator: the allow-listed verb forwards; any other breaks.
(define mb-ro (session-send mb-session mb-root 'make-readonly mb-tool))
(expect (= 7 (session-send mb-session mb-ro 'get)) "proxy: attenuator forwards an allowed verb")
(define mb-denied
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send mb-session mb-ro 'add 1) #f))
(expect (and (exn:fail:pancake? mb-denied)
             (regexp-match? #rx"Attenuated" (exn-message mb-denied)))
        "proxy: an out-of-list verb breaks Attenuated")

;; Revoke: every later call through the proxy breaks.
(void (session-send mb-session mb-root 'revoke))
(define mb-severed
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send mb-session mb-proxy 'add 1) #f))
(expect (and (exn:fail:pancake? mb-severed)
             (regexp-match? #rx"Revoked" (exn-message mb-severed)))
        "proxy: a revoked proxy breaks Revoked")

(session-close! mb-session)
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
       (define hsession (accept lc-server))
       (session-publish hsession "tool" ^ping)
       (semaphore-post lc-ready)
       (session-serve hsession)
       (channel-put lc-ch 'served)))))

(define lc-session (connect (tcp-locator "127.0.0.1" (server-port lc-server))))
(semaphore-wait lc-ready)

;; A caretaker over a local tool, called locally by its own host.
(define lc-local (session-spawn lc-session ^doubler))
(define lc-care (session-caretaker lc-session lc-local))
(expect (= 42 (session-send lc-session lc-care 'double 21))
        "local-call: a local proxy answers a local call")

;; A caretaker over a far tool, called locally: the proxy forwards across the wire
;; and the local send still settles on the partner's reply.
(define lc-far (session-fetch lc-session "tool"))
(define lc-care-far (session-caretaker lc-session lc-far))
(expect (= 99 (session-send lc-session lc-care-far 'ping))
        "local-call: a local call over a far tool settles")

;; Revoke severs the local call exactly as it severs a partner's.
(session-revoke! lc-session lc-care)
(define lc-severed
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send lc-session lc-care 'double 1) #f))
(expect (and (exn:fail:pancake? lc-severed)
             (regexp-match? #rx"Revoked" (exn-message lc-severed)))
        "local-call: revoke breaks a local call too")

(session-close! lc-session)
(define lc-host-result (channel-get lc-ch))
(when (exn? lc-host-result) (raise lc-host-result))
(server-close! lc-server)

(printf "racket zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)\n")

;; ── The callback latch crosses the binding ────────────────────────────────────
;; A behavior that reaches for a host-driving verb mid-turn (session-fetch, here)
;; is refused by the C tier before it can block, the refusal surfaces as the
;; method's own raise, and the answer breaks with it — the turn neither
;; deadlocks nor corrupts the host. This is the loud edge of the binding rule
;; that a handler must not drive (or block on) the host inside its own turn.
;; The connection stays fully usable afterwards.
(define rt-server (listen "127.0.0.1" 0))
(define rt-ready (make-semaphore 0))
(define rt-ch (make-channel))
(define rt-host
  (thread
   (lambda ()
     (define hsession (accept rt-server))
     (session-publish hsession "svc"
                   (lambda (bcom)
                     (methods
                      [(reenter) (session-fetch hsession "nested")]
                      [(ping) (sym "pong")])))
     (semaphore-post rt-ready)
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rt-ch e))])
       (session-serve hsession)
       (channel-put rt-ch 'served)))))

(define rt-session (connect (tcp-locator "127.0.0.1" (server-port rt-server))))
(semaphore-wait rt-ready)
(define rt-cap (session-fetch rt-session "svc"))
(define rt-broken
  (with-handlers ([exn:fail:pancake? values])
    (session-send rt-session rt-cap 'reenter) #f))
(expect (exn:fail:pancake? rt-broken)
        "reentry: a mid-turn driving verb breaks the answer")
;; The turn unwound cleanly: the same session still answers.
(expect (equal? (sym "pong") (session-send rt-session rt-cap 'ping))
        "reentry: the connection survives the refused turn")
(session-close! rt-session)
(define rt-host-result (channel-get rt-ch))
(when (exn? rt-host-result) (raise rt-host-result))
(server-close! rt-server)

(printf "racket zig-smoke OK: a behavior's mid-turn driving verb is refused and breaks its own answer\n")

;; ── Mid-turn close parks the C release ────────────────────────────────────────
;; A behavior that calls `session-close!` inside its own *wire* turn must not
;; free the native conn while the trampoline frame is still on the stack. Local
;; vat turns do not set `inside-turn?` (they never enter the C latch); the park
;; is for the hosted trampoline path. Closing the transport drops the partner
;; before the reply can settle on the wire — the proof here is the park count
;; observed *during* the turn (1), not a far reply.
(define mc-server (listen "127.0.0.1" 0))
(define mc-ready (make-semaphore 0))
(define mc-during (make-channel))
(define mc-ch (make-channel))
(define mc-acceptor
  (thread
   (lambda ()
     (define hsession (accept mc-server))
     (session-publish hsession "svc"
                   (lambda (_bcom)
                     (methods
                      [(die)
                       (session-close! hsession)
                       ;; Still inside the trampoline: the release must be parked.
                       (channel-put mc-during
                                    (host-pending-release-count (session-host hsession)))
                       (sym "closing")])))
     (semaphore-post mc-ready)
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put mc-ch e))])
       (session-serve hsession)
       (channel-put mc-ch 'served)))))

(define mc-session (connect (tcp-locator "127.0.0.1" (server-port mc-server))))
(semaphore-wait mc-ready)
(define mc-svc (session-fetch mc-session "svc"))
;; Drive the deliver without awaiting a reply: closing the exporter mid-turn
;; drops the wire before a settle can land. A bounded thread races the send.
(define mc-client
  (thread
   (lambda ()
     (with-handlers ([exn:fail:pancake? void])
       (session-send mc-session mc-svc 'die)))))
(define mc-parked (sync/timeout 10 mc-during))
(expect (equal? 1 mc-parked)
        (format "mid-turn-close: release parked during the trampoline turn (got ~a)" mc-parked))
(thread-wait mc-client)
(session-close! mc-session)
(define mc-host-result (sync/timeout 10 mc-ch))
(when (exn? mc-host-result) (raise mc-host-result))
(server-close! mc-server)

(printf "racket zig-smoke OK: a behavior closing its own connection mid-turn parks the release\n")

;; ── Time-travel: restore retargets wire delivers ──────────────────────────────
;; The README's headline time-travel claim, pinned over the wire: snapshot a
;; served vat, mutate the actor through wire delivers, restore, and observe
;; the NEXT wire deliver hit the restored behavior — proving `vat-restore!`
;; retargets what the trampoline dispatches, not just local `$` calls.
(define tt-server (listen "127.0.0.1" 0))
(define tt-ready (make-semaphore 0))
(define tt-vat-box (box #f))
(define tt-host
  (thread
   (lambda ()
     (define hsession (accept tt-server #:time-travel? #t))
     (set-box! tt-vat-box (session-vat hsession))
     (session-publish hsession "counter" ^counter 10)
     (semaphore-post tt-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession)))))
(define tt-session (connect (tcp-locator "127.0.0.1" (server-port tt-server))))
(semaphore-wait tt-ready)
(define tt-cap (session-fetch tt-session "counter"))
(expect (= 15 (session-send tt-session tt-cap 'add 5)) "time-travel: first wire add lands")
(define tt-snap (vat-snapshot (unbox tt-vat-box)))
(expect (= 115 (session-send tt-session tt-cap 'add 100)) "time-travel: second wire add lands")
(vat-restore! (unbox tt-vat-box) tt-snap)
;; The next WIRE deliver must see the restored state (15), not the later one.
(expect (= 15 (session-send tt-session tt-cap 'get))
        "time-travel: restore retargeted the wire deliver to the snapshot state")
(expect (= 22 (session-send tt-session tt-cap 'add 7))
        "time-travel: the restored behavior keeps serving from the snapshot")
(session-close! tt-session)
(server-close! tt-server)

(printf "racket zig-smoke OK: vat-restore! retargets wire delivers to the snapshot state\n")

;; ── Listener fires run outside the host lock ──────────────────────────────────
;; An `on` listener is arbitrary application code; the drain that settles its
;; vow runs under the host lock, so the fire itself is deferred to after the
;; lock releases — a listener that ran under the lock could wedge every other
;; thread sharing the host. The listener proves it directly: at fire time this
;; thread must not own the host lock, and an enqueueing verb (a tell) must go
;; through. (Fires also run after the reader gate clears, so a listener may
;; pump this connection — but must not block the reader turn that produced
;; the settle; enqueue and return.)
(define lf-server (listen "127.0.0.1" 0))
(define lf-ready (make-semaphore 0))
(define lf-told (make-channel))
(define lf-acceptor
  (thread
   (lambda ()
     (define hsession (accept lf-server))
     (session-publish hsession "svc"
                   (lambda (bcom)
                     (methods
                      [(first) 1]
                      [(notify) (channel-put lf-told 'told) 2])))
     (semaphore-post lf-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession)))))
(define lf-session (connect (tcp-locator "127.0.0.1" (server-port lf-server))))
(semaphore-wait lf-ready)
(define lf-svc (session-fetch lf-session "svc"))
(define lf-host (session-host lf-session))
(define lf-under-lock (box 'unfired))
(define lf-vow (with-vat (session-vat lf-session) (<- lf-svc 'first)))
(with-vat (session-vat lf-session)
  (on lf-vow
      (lambda (v)
        (set-box! lf-under-lock (eq? (unbox (host-lock-owner lf-host)) (current-thread)))
        ;; An enqueueing verb from inside the fire: legal, takes the host lock
        ;; the fire no longer holds.
        (session-tell lf-session lf-svc 'notify))))
(expect (= 1 (session-await lf-session lf-vow)) "listener-fire: the send settled")
(expect (eq? #f (unbox lf-under-lock))
        "listener-fire: the fire ran with the host lock released")
(expect (eq? 'told (sync/timeout 10 lf-told))
        "listener-fire: the listener's tell reached the partner")
(session-close! lf-session)
(server-close! lf-server)

(printf "racket zig-smoke OK: an on listener fires outside the host lock and can enqueue\n")

;; ── A redeem dial must not park the host ──────────────────────────────────────
;; The recipient half of a three-party handoff opens its own socket to the
;; exporter (a DIAL action). A dial is a connect syscall plus a whole keyed
;; handshake, so the drain defers it post-lock like every write and fire: a
;; slow exporter stalls that one redeem, never every thread sharing the host.
;; Proven with a deterministic stall — the exporter listens but does not
;; accept, so the redeem dial's connect lands in the listen backlog and its
;; handshake parks — while a sibling connection on the recipient's host
;; completes a full send. Releasing the exporter then lets the parked redeem
;; finish end-to-end, which also proves the whole hermetic three-party flow:
;; gift originated by the gifter's host, deposited on the exporter, withdrawn
;; over a real DIAL, and the redeemed capability called directly.
(define rd-e-server (listen "127.0.0.1" 0))
;; Host-wide, not session-published: the withdraw arrives on the session the
;; recipient's redeem dial opens later, and the exporter resolves the gifted
;; swissnum against that session's own bootstrap registry.
(host-publish-giftable (server-host rd-e-server) "gifted" (methods [(use) 7]))
(define rd-release-e (make-semaphore 0))
(define rd-e-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       ;; Accept exactly one connection now — the gifter's — and serve it so
       ;; the gifter's deposit is read. The recipient's redeem dial waits in
       ;; the listen backlog until released.
       (define hsession (accept rd-e-server))
       (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))
       (semaphore-wait rd-release-e)
       (define rconn (accept rd-e-server))
       (with-handlers ([(lambda (_) #t) void]) (session-serve rconn))))))
(define rd-g-server (listen "127.0.0.1" 0))
;; Sibling probe peer: a second listen so the recipient host can hold two
;; live sessions without a second dial to the same address designator
;; (SessionPairExists). Same host, different partner — that is the lock pin.
(define rd-ping-server (listen "127.0.0.1" 0))
;; The gifter dials the exporter on its server's host, so the tool it fetches
;; and the introductions it serves share one identity and gift registry.
(define rd-gc (connect (tcp-locator "127.0.0.1" (server-port rd-e-server))
                       #:host (server-host rd-g-server)))
(define rd-tool (session-fetch rd-gc "gifted"))
(define rd-g-ready (make-semaphore 0))
(define rd-g-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (let accept-loop ([first? #t])
         (define hsession (accept rd-g-server))
         (session-publish hsession "intro"
                       (lambda (bcom)
                         (methods
                          ;; Replying with a capability that lives on another
                          ;; connection makes the host originate a give.
                          [(get-tool) rd-tool])))
         (when first? (semaphore-post rd-g-ready))
         (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))
         (accept-loop #f))))))
(define rd-ping-ready (make-semaphore 0))
(define rd-ping-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept rd-ping-server))
       (session-publish hsession "ping"
                     (lambda (bcom) (methods [(ping) "pong"])))
       (semaphore-post rd-ping-ready)
       (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))))
(define rd-r-main (connect (tcp-locator "127.0.0.1" (server-port rd-g-server))))
(semaphore-wait rd-g-ready)
(define rd-r-side (connect (tcp-locator "127.0.0.1" (server-port rd-ping-server))
                           #:host (session-host rd-r-main)))
(semaphore-wait rd-ping-ready)
(define rd-intro-main (session-fetch rd-r-main "intro"))
(define rd-ping-side (session-fetch rd-r-side "ping"))
;; Trigger the handoff: the reply is a give, the recipient's host auto-redeems
;; it, and the send settles only after the withdraw — so this thread is parked
;; in the stalled dial until the exporter is released.
(define rd-tool-ch (make-channel))
(void (thread
       (lambda ()
         (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rd-tool-ch e))])
           (channel-put rd-tool-ch (session-send rd-r-main rd-intro-main 'get-tool))))))
;; The dial is provably in flight once its connect reaches the exporter's
;; listen backlog.
(let wait-for-dial ([tries 0])
  (unless (tcp-accept-ready? (server-listener rd-e-server))
    (when (> tries 3000) (fail "redeem-dial: the redeem dial never reached the exporter"))
    (sleep 0.01)
    (wait-for-dial (add1 tries))))
;; THE PIN: with the dial stalled mid-handshake, a sibling connection sharing
;; the recipient's host must still complete a full send. If the dial executor
;; held the host lock, this send would wedge and the timeout would fail loud.
(define rd-probe-ch (make-channel))
(void (thread
       (lambda ()
         (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rd-probe-ch e))])
           (channel-put rd-probe-ch (session-send rd-r-side rd-ping-side 'ping))))))
(define rd-probe (sync/timeout 15 rd-probe-ch))
(expect (equal? rd-probe "pong")
        "redeem-dial: a sibling send settled while the dial was stalled")
;; Release the exporter: the parked handshake completes, the withdraw settles,
;; and the redeemed capability answers a direct call.
(semaphore-post rd-release-e)
(define rd-tool-cap (sync/timeout 30 rd-tool-ch))
(expect (and rd-tool-cap (not (exn? rd-tool-cap)))
        "redeem-dial: the gifted capability settled after the exporter released")
(expect (= 7 (session-send rd-r-main rd-tool-cap 'use))
        "redeem-dial: the redeemed capability answered a direct call")
(session-close! rd-r-main)
(session-close! rd-r-side)
(session-close! rd-gc)
(server-close! rd-g-server)
(server-close! rd-ping-server)
(server-close! rd-e-server)

(printf "racket zig-smoke OK: a redeem dial runs post-lock and a stalled exporter parks one redeem, not the host\n")

;; ── À-la-carte transports: one round-trip over each composable transport module ─
;; Each transport archive ships as its own composable module (`pancake-tcp.rkt`,
;; `pancake-inproc.rkt`) whose endpoints shuttle whole frames. These two
;; sections drive the *same* full deliver/serve/resolve round-trip between two
;; byte-fed host connections over each explicit netlayer's endpoints, proving a
;; Racket consumer composes the host tier with a transport à la carte exactly
;; as a C consumer links the archives. Each side is a real `connection` (its
;; own node, vat, and keyed handshake); only the transport's (read, write) pair
;; differs, so the driving logic is shared.
;;
;; The exchange is single-threaded on purpose. Unlike Racket's own
;; scheduler-aware ports, these explicit C-ABI netlayers park the whole Racket
;; place for the duration of a foreign read or write, so two connections cannot
;; rendezvous across green threads in one place. The script therefore orders
;; every blocking read after the frame it waits for is already in flight: both
;; hellos leave before either side pumps its handshake, and each fetch/call leg
;; feeds exactly the frame the previous leg wrote.
(define (endpoint-transport read-frame write-frame!)
  (async-transport
   (lambda (frame) (write-frame! frame))
   void
   (lambda (_wake) (read-frame))
   void))

;; The minting half of `session-fetch`, without its blocking pump: queue the
;; bootstrap fetch, register the vow so the drain can route its completion,
;; and flush; the caller shuttles the frames and reads the vow's state.
(define (scripted-fetch! c name)
  (define m (session-host c))
  (with-host-drain m
    (lambda ()
      (define nb (string->bytes/utf-8 name))
      (define-values (rc id)
        (pancake_host_session_fetch (session-ptr c) (pin-immobile nb) (bytes-length nb)))
      (check/host rc)
      (define fresh (session-vow c id 'pending '()))
      (register-vow! m fresh)
      ;; The drain parks the fetch deliver on the connection's pending-writes
      ;; FIFO; `with-host-drain` runs the write once the lock releases, like
      ;; every drain.
      (values (drain-host-actions! m) fresh))))

;; Read one whole frame off the endpoint and feed its bytes (the feed drains,
;; so a reply this frame provokes is written back through the same transport).
(define (feed-next! c read-frame) (feed-bytes! c (read-frame)))

(define (transport-counter-roundtrip client-read client-write! server-read server-write!)
  (define chost (make-fresh-host))
  (define shost (make-fresh-host))
  ;; Both hellos leave before either side pumps, so neither establish blocks.
  (define client-session (open-dialed-over chost "tcp" (socket-addr-designator "127.0.0.1" 1)
                                        (endpoint-transport client-read client-write!)))
  (drain-host! chost)  ; the dialer's signed op:start-session is in flight
  (define server-session (open-accepted-over shost "tcp" (socket-addr-designator "127.0.0.1" 2)
                                          (endpoint-transport server-read server-write!)))
  (drain-host! shost)  ; the acceptor's hello crosses it
  (finish-establish! server-session)
  (finish-establish! client-session)
  ;; Publish, fetch, call: deliver, serve, resolve, one leg at a time.
  (session-publish server-session "counter" ^counter 10)
  (define fetched (scripted-fetch! client-session "counter"))
  (feed-next! server-session server-read)   ; the bootstrap fetch deliver
  (feed-next! client-session client-read)   ; its resolution settles the fetch
  (expect (and (pair? (session-vow-state fetched)) (eq? 'ok (car (session-vow-state fetched))))
          "transport: the scripted fetch fulfilled")
  (define counter-ref (cdr (session-vow-state fetched)))
  (expect (far-ref? counter-ref) "transport: fetched a far capability")
  (define vow (session-far-send client-session counter-ref 'add '(5) #t))
  (drain-host! chost)                    ; the deliver leaves
  (feed-next! server-session server-read)   ; the served turn runs, the resolve leaves
  (feed-next! client-session client-read)   ; the resolve settles the vow
  (define settled (session-vow-state vow))
  (session-close! client-session)
  (session-close! server-session)
  (and (pair? settled) (eq? 'ok (car settled)) (cdr settled)))

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
(inproc-endpoint-release! inproc-client)
(inproc-endpoint-release! inproc-server)
(inproc-listener-release! inproc-lst)
(inproc-netlayer-release! inproc-nl)

(printf "racket zig-smoke OK: drove OCapN over the socket-free in-process netlayer\n")

;; libpancake_net_transport_tcp: the explicit C-ABI TCP netlayer (cleartext,
;; loopback-grade). Same round-trip over real sockets, proving the tcp module
;; composes with the host tier just as inproc does, a different archive, one core.
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
(endpoint-release! tcp-client)
(endpoint-release! tcp-server)
(listener-release! tcp-lst)
(netlayer-release! tcp-nl)

(printf "racket zig-smoke OK: drove OCapN over the C-ABI TCP netlayer\n")
