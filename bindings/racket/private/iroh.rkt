#lang racket/base
;; The iroh transport companion's implementation.
;;
;; `../pancake-iroh.rkt` is the application-facing barrel over this module and
;; re-exports only the hosting surface. This file lives in the private tree so
;; the binding can reach the raw endpoint and resident seam without a submodule.
;;
;; Mirrors the à-la-carte archive split (ADR-0059): `pancake.rkt` is the core
;; (libpancake_ocapn), and each transport is its own composable module —
;; `pancake-tcp.rkt`, `pancake-inproc.rkt`, and this one. This module is
;; libpancake_net_transport_iroh's binding, the optional encrypted-QUIC netlayer.
;; Its private loader (`private/ffi-iroh.rkt`) opens ONLY the iroh companion
;; (`zig build iroh-abi`, needs cargo) — which exports only `pancake_iroh_*` —
;; and builds an `async-transport` over it through the transport seam
;; (`private/seam.rkt`); the core calls come from there. Everything above the
;; pump — vat, session-* verbs, events — is the core's; only the transport differs.
;;
;; `connect` in the core dials an iroh locator by loading this module lazily, so a
;; TCP-only program never needs the iroh library. `listen-iroh` registers the
;; endpoint as a provider with the native loop; the raw `iroh-endpoint` byte
;; path remains for consumers that run their own protocol.

(require ffi/unsafe
         ffi/unsafe/port
         racket/lazy-require
         racket/random
         "constants.rkt"
         "errors.rkt"
         "ffi-iroh.rkt"
         "seam.rkt"
         "byte-channel.rkt"
         "host.rkt"
         (only-in "locator.rkt"
                  parse-locator locator-transport locator-designator locator-hints))

(lazy-require
 ["loop.rkt"
   (open-driver-loop
   driver-loop-start!
   driver-loop-abort!
   driver-loop-add-provider!
   driver-loop-host
   loop-listen!
   loop-listener-close!
   loop-listener-locator
   loop-listener-select!
   make-loop-server
   loop-server-locator
   loop-server-host
   loop-server-accept
   loop-server-close!)])

(provide iroh-loop-provider-parts iroh-adopt-loop!
         make-iroh-config (struct-out iroh-config)
         listen-iroh
         IROH-REACH-DIRECT IROH-REACH-DISCOVERY IROH-REACH-DISCOVERY-NO-RELAY IROH-REACH-LOCAL-DISCOVERY
         iroh-server-node-id iroh-server-direct-addresses
         iroh-server-host iroh-server-accept iroh-server-close!
         dial-locator-for-relay
         open-iroh-endpoint
         iroh-endpoint-node-id iroh-endpoint-direct-addresses
         iroh-endpoint-accept iroh-endpoint-dial iroh-endpoint-close!
         ;; The shape those two answer with, re-provided so a consumer reaching
         ;; the barrel needs no second require for the struct it is handed.
         (struct-out byte-channel))

;; Reachability posture, REQUIRED on every public iroh constructor, with NO
;; default: a peer states how it is reachable, the binding never guesses. The
;; IROH-REACH-* values come from the generated constants module
;; (`private/constants-gen.rkt`, re-provided by `private/constants.rkt`), so
;; they cannot drift from the C ABI. The lazy iroh ABI loader behind `iroh-fn`
;; lives in `private/ffi-iroh.rkt`.

;; ── netlayer FFI wrappers ─────────────────────────────────────────────────────
;; (iroh-last-error) -> the calling thread's last error message from the iroh
;; archive, or #f when there is none. The iroh archive keeps its own
;; thread-local slot (`pancake_iroh_last_error`), symbol-disjoint from the
;; ocapn family's `last-error`. Query the length first (NULL buffer), then read.
(define (iroh-last-error) (read-last-error (iroh-fn 'last-error)))

;; Raise the same typed exn `check` raises, but read the diagnostic from the
;; iroh archive's own last-error rather than the unrelated ocapn-family one.
(define (check/iroh code) (check-with code iroh-last-error))

;; The iroh endpoint handle, wrapped in a mutable struct the way the TCP netlayer
;; is (`pancake-tcp.rkt`'s `(struct netlayer (handle) #:mutable)`). Wrapping lets
;; close/release null the handle and stay idempotent, so a finalizer fallback can
;; release the endpoint (and its OS fd) when the caller drops the owner without an
;; explicit close, exactly the release-fallback parity every other handle in this
;; binding already has (ADR-0057's loop still roots the live netlayer through
;; `lp`, so no weak box is involved — the fallback rides the owner wrappers the
;; loop thread does not root).
(struct iroh-netlayer (handle) #:mutable)

;; `reachability` is required, an IROH-REACH-* posture, no default.
;; `seed` is a 32-byte Ed25519 secret for a stable endpoint id, or omitted for
;; a fresh random key. Returns the netlayer and the seed that drove it so a
;; caller can mint a Host from the same bytes (ADR-0075).
;; One iroh endpoint's configuration, field-for-field with the header's
;; `PancakeIrohConfig`, which documents what each setting means. `#f` for a
;; timeout takes the transport's default.
;;
;; `reachability` is mandatory: enabling relays or a discovery service is always
;; the caller's visible choice. `connect-timeout-ms` bounds getting a connection
;; up, `idle-timeout-ms` bounds keeping one. Set `idle-timeout-ms` if you read a
;; live session as presence, because it is what ends a connection whose peer was
;; killed rather than closed.
(struct iroh-config (reachability connect-timeout-ms idle-timeout-ms worker-threads)
  #:transparent)

(define (make-iroh-config reachability
                          #:connect-timeout-ms [connect-timeout-ms #f]
                          #:idle-timeout-ms [idle-timeout-ms #f]
                          #:worker-threads [worker-threads #f])
  (iroh-config reachability connect-timeout-ms idle-timeout-ms worker-threads))

;; Configuration authority for a loop's registered iroh provider. The native
;; endpoint is intentionally absent: registration owns its callback context,
;; and the binding drops its construction reference immediately afterwards.
(struct loop-iroh-binding (config seed) #:transparent)
(define loop-iroh-bindings (make-weak-hasheq))

(define (iroh-netlayer-new config [seed #f])
  (define seed* (or seed (crypto-random-bytes 32)))
  (define-values (rc h)
    ;; 0 = the built-in default for any of them (the header's zero-init contract).
    ((iroh-fn 'netlayer-new) (pin-immobile seed*) (bytes-length seed*)
                             (make-PancakeIrohConfig
                              (iroh-config-reachability config)
                              (or (iroh-config-connect-timeout-ms config) 0)
                              (or (iroh-config-idle-timeout-ms config) 0)
                              (or (iroh-config-worker-threads config) 0))))
  (check/iroh rc)
  (values (iroh-netlayer h) seed*))

(define (iroh-netlayer-node-id nl)
  (define buf (make-bytes 64)) ; an endpoint id is 64 lowercase-hex bytes
  (define-values (rc len) ((iroh-fn 'netlayer-node-id) (iroh-netlayer-handle nl) buf 64))
  (check/iroh rc)
  (bytes->string/utf-8 (subbytes buf 0 len)))

(define (iroh-netlayer-direct-addresses nl)
  ;; A buffer too small is ERR-BUFFER-TOO-SMALL; grow until the comma-separated
  ;; hint string fits (loopback hints are short, but be safe).
  (let loop ([cap 256])
    (define buf (make-bytes cap))
    (define-values (rc len) ((iroh-fn 'netlayer-direct-addrs) (iroh-netlayer-handle nl) buf cap))
    (cond
      [(and (= rc ERR-BUFFER-TOO-SMALL) (< cap (* 64 1024))) (loop (* cap 4))]
      [else (check/iroh rc) (bytes->string/utf-8 (subbytes buf 0 len))])))

;; Admit one dial without parking the place. The sidecar parses the borrowed
;; bytes before return and publishes the terminal result through EV-CONNECT.
(define (iroh-netlayer-start-connect nl request-id node-id hints)
  (define nb (string->bytes/utf-8 node-id))
  (define hb (string->bytes/utf-8 hints))
  (define nbuf (pin-immobile nb))
  (define hbuf (pin-immobile hb))
  (check/iroh
   ((iroh-fn 'netlayer-start-connect)
    (iroh-netlayer-handle nl) request-id
    nbuf (bytes-length nb) hbuf (bytes-length hb))))

(define (iroh-netlayer-finish-connect nl request-id)
  (define-values (rc conn)
    ((iroh-fn 'netlayer-finish-connect) (iroh-netlayer-handle nl) request-id))
  (check/iroh rc)
  conn)

(define (iroh-netlayer-cancel-connect nl request-id)
  (check/iroh
   ((iroh-fn 'netlayer-cancel-connect) (iroh-netlayer-handle nl) request-id)))

;; The archive-owned provider package for a fresh iroh endpoint.
(define (iroh-loop-provider-parts reachability [seed #f])
  (define-values (netlayer _seed)
    (iroh-netlayer-new (make-iroh-config reachability) seed))
  (define close! (lambda () (iroh-netlayer-close/release! netlayer)))
  (define package (make-PancakeTransportProvider 0 0 #f 0 #f #f #f))
  (with-handlers ([(lambda (_) #t) (lambda (e) (close!) (raise e))])
    (check/iroh ((iroh-fn 'transport-provider) (iroh-netlayer-handle netlayer) package)))
  (values netlayer package close!))

;; The iroh companion owns loop configuration and reuse. The generic driver
;; receives only the archive-owned provider package.
(define (iroh-adopt-loop! lp config #:seed [seed #f])
  (define seed*
    (bytes->immutable-bytes
     (or seed (host-seed (driver-loop-host lp)))))
  (unless (= (bytes-length seed*) 32)
    (raise-pancake 'iroh-adopt-loop! ERR-INVALID-ARGUMENT
                   "the iroh provider seed must be 32 bytes"))
  (define existing (hash-ref loop-iroh-bindings lp #f))
  (cond
    [existing
     (unless (and (equal? (loop-iroh-binding-config existing) config)
                  (bytes=? (loop-iroh-binding-seed existing) seed*))
       (raise-pancake 'iroh-adopt-loop! ERR-INVALID-ARGUMENT
                      "the loop's iroh endpoint configuration or durable seed conflicts"))
     existing]
    [else
     (define-values (netlayer package close!)
       (iroh-loop-provider-parts (iroh-config-reachability config) seed*))
     (define binding (loop-iroh-binding config seed*))
     (with-handlers
         ([(lambda (_) #t)
           (lambda (e)
             (when (eq? (hash-ref loop-iroh-bindings lp #f) binding)
               (hash-remove! loop-iroh-bindings lp))
             (close!)
             (raise e))])
       ;; Publish only immutable state before registration. If registration
       ;; fails, the handler removes it and closes the unregistered endpoint.
       (hash-set! loop-iroh-bindings lp binding)
       (driver-loop-add-provider! lp package)
       ;; Registration retained the callback context. Drop only the
       ;; constructor's reference; shutting the endpoint down would invalidate
       ;; the provider that the driver now owns.
       (iroh-netlayer-release-construction! netlayer)
       binding)]))

;; Close then release the endpoint, nulling the handle FIRST so a second teardown
;; — an explicit close racing the finalizer, or the reverse — sees #f and does
;; nothing, never a double close or double release. The caller must have stopped
;; the readiness loop first (`loop-stop!` joins its thread), so no foreign call
;; still touches the endpoint when this runs.
(define (iroh-netlayer-close/release! nl)
  (define h (iroh-netlayer-handle nl))
  (when h
    (set-iroh-netlayer-handle! nl #f)
    ((iroh-fn 'netlayer-close) h)
    ((iroh-fn 'netlayer-release) h)))

;; Drop a construction reference after a successful provider registration.
;; Unlike `iroh-netlayer-close/release!`, this does not shut down the endpoint:
;; the driver's retained provider lease is the authority that keeps callback
;; context alive until loop teardown.
(define (iroh-netlayer-release-construction! nl)
  (define h (iroh-netlayer-handle nl))
  (when h
    (set-iroh-netlayer-handle! nl #f)
    ((iroh-fn 'netlayer-release) h)))

;; ── the iroh readiness loop (ADR-0057) ────────────────────────────────────────
;; The Racket sibling of the Deno binding's `IrohLoop`, the Python binding's
;; `_IrohLoop`, and Zig's `completion.Loop(iroh.Backend)` + `driver.Bridge` +
;; `driver_core.Host`: one green thread multiplexes
;; many connections instead of parking a blocking read per connection. The
;; netlayer exposes one OS readiness fd; the loop thread parks on it natively with
;; `unsafe-file-descriptor->semaphore` — the place's rktio poller wakes the
;; semaphore when the fd is readable, so the thread truly sleeps (no busy-poll)
;; while every other green thread on the place keeps running. On each wake it
;; drains the pending records with `drain-ready` and posts each to the connection
;; (or the accept queue) waiting on it. The per-connection try-read / try-write
;; never block, so a connection can be released at any time without racing a read.
;; (Green threads are cooperative within a place, so the `conns` table and waiters
;; mutate only while a thread is scheduled, never concurrently with a foreign
;; call.)

(define DRAIN-READY-CAP 64) ; records pulled per `drain-ready`; a deeper queue re-drains until short
(define READ-CHUNK 65536)

;; Per-connection readiness gates: a semaphore the loop posts on each readable /
;; writable edge (counting, so an edge that arrives before its waiter parks is
;; not lost), a `closed?` flag the loop raises on a close record, the conn handle
;; itself (so `loop-stop!` can release leftovers), and a shared `released?` box
;; so transport close! and loop-stop! never double-call conn-release.
(struct conn-waiters (conn readable writable released? [closed? #:mutable]))
(struct dial-waiter (sema result [abandoned? #:mutable]))

;; One readiness loop per netlayer: the netlayer it watches, the address→waiters
;; table, the accept gate (posted on each accept record), a stop event the loop
;; thread syncs alongside the fd so a close wakes it at once, and the dedicated
;; readiness thread. `buf` is the reused record array the loop drains into.
(struct iroh-loop (netlayer conns dials [next-request #:mutable] accept-sema stop-sema [accept-closed? #:mutable] [stop? #:mutable] [thread #:mutable] buf))

;; Stable sidecar identity, never the allocation address.
(define (conn-key conn) ((iroh-fn 'conn-id) conn))

;; Spawn the netlayer's readiness thread. The loop is already armed (the netlayer
;; arms it at construction), so this only stands up the fd-parking thread.
(define (make-iroh-loop netlayer)
  (define lp (iroh-loop netlayer (make-hash) (make-hash) 1 (make-semaphore 0) (make-semaphore 0) #f #f #f
                        (malloc _PancakeIrohReadyEvent DRAIN-READY-CAP 'atomic-interior)))
  (set-iroh-loop-thread! lp (thread (lambda () (loop-run lp))))
  lp)

(define (loop-dial! lp node-id hints)
  (define request-id (iroh-loop-next-request lp))
  (set-iroh-loop-next-request! lp (add1 request-id))
  (define w (dial-waiter (make-semaphore 0) (box #f) #f))
  (hash-set! (iroh-loop-dials lp) request-id w)
  (with-handlers ([exn?
                   (lambda (e)
                     (hash-remove! (iroh-loop-dials lp) request-id)
                     (raise e))])
    (iroh-netlayer-start-connect (iroh-loop-netlayer lp) request-id node-id hints))
  (define completed? #f)
  (dynamic-wind
   void
   (lambda ()
     (semaphore-wait (dial-waiter-sema w))
     (set! completed? #t)
     (define result (unbox (dial-waiter-result w)))
     (case (car result)
       [(ok) (cdr result)]
       [(error) (raise (cdr result))]
       [else (raise-pancake 'iroh ERR-CLOSED "iroh loop closed")]))
   (lambda ()
     (unless completed?
       (set-dial-waiter-abandoned?! w #t)
       (iroh-netlayer-cancel-connect (iroh-loop-netlayer lp) request-id)))))

(define (loop-register! lp conn)
  (hash-set! (iroh-loop-conns lp) (conn-key conn)
             (conn-waiters conn (make-semaphore 0) (make-semaphore 0) (box #f) #f)))

;; Idempotent conn-release shared by transport close! and loop-stop!.
(define (release-conn-once! w)
  (define released? (conn-waiters-released? w))
  (unless (unbox released?)
    (set-box! released? #t)
    ((iroh-fn 'conn-release) (conn-waiters-conn w))))

;; Drop a connection's routing entry and wake any waiter with a closed signal, so
;; a fill or write parked on it unwinds. Releasing the handle afterwards is safe:
;; no call parks on it.
(define (loop-unregister! lp conn)
  (define w (hash-ref (iroh-loop-conns lp) (conn-key conn) #f))
  (when w
    (hash-remove! (iroh-loop-conns lp) (conn-key conn))
    (wake-closed! w)))

(define (wake-closed! w)
  (set-conn-waiters-closed?! w #t)
  (semaphore-post (conn-waiters-readable w))
  (semaphore-post (conn-waiters-writable w)))

;; Wake every waiter (accept gate + each connection) with a closed signal, so a
;; fill, write, or accept parked on the loop unwinds. Shared by the close path
;; and the endpoint-fault path.
(define (wake-all! lp)
  (set-iroh-loop-accept-closed?! lp #t)
  (semaphore-post (iroh-loop-accept-sema lp))
  (for ([(_k w) (in-hash (iroh-loop-conns lp))]) (wake-closed! w)))

;; Stop the loop and join its readiness thread, waking every waiter so parked
;; pumps unwind, then release every connection still registered (TS/Python
;; parity). Posting the stop event wakes the thread from its fd park at once;
;; it sees `stop?` and exits, deregistering the fd. The caller releases the
;; netlayer after, with no foreign call still touching it.
(define (loop-stop! lp)
  (unless (iroh-loop-stop? lp)
    (set-iroh-loop-stop?! lp #t)
    (semaphore-post (iroh-loop-stop-sema lp))
    (wake-all! lp)
    (for ([(_k w) (in-hash (iroh-loop-conns lp))])
      (release-conn-once! w))
    (hash-clear! (iroh-loop-conns lp))
    (for ([(request-id w) (in-hash (iroh-loop-dials lp))])
      (with-handlers ([exn? void])
        (iroh-netlayer-cancel-connect (iroh-loop-netlayer lp) request-id))
      (set-box! (dial-waiter-result w) (cons 'closed #f))
      (semaphore-post (dial-waiter-sema w)))
    (hash-clear! (iroh-loop-dials lp))
    (define t (iroh-loop-thread lp))
    (when t (thread-wait t))))

;; Drain the ready-queue in batches until a short count, posting each record to
;; its waiter. Returns #f when the endpoint faulted (a negative drain), so the
;; loop can wind down. A `drain-ready` call also clears the fd's wakeup bytes.
(define (loop-drain! lp)
  (define buf (iroh-loop-buf lp))
  (let drain ()
    (define-values (rc n) ((iroh-fn 'netlayer-drain-ready) (iroh-netlayer-handle (iroh-loop-netlayer lp)) buf DRAIN-READY-CAP))
    (cond
      [(not (= rc OK)) #f]
      [(= n 0) #t]
      [else
       (for ([i (in-range n)])
         (define rec (ptr-ref buf _PancakeIrohReadyEvent i))
         (dispatch! lp (PancakeIrohReadyEvent-subject rec) (PancakeIrohReadyEvent-events rec)))
       (if (= n DRAIN-READY-CAP) (drain) #t)])))

;; The dedicated readiness thread: park on the netlayer's readiness fd, and on
;; each wake drain the records and post them to the waiting connections. The park
;; is native — `unsafe-file-descriptor->semaphore` registers the fd with the
;; place's poller and posts the semaphore when it is readable — so the thread
;; truly sleeps without freezing the place.
(define (loop-run lp)
  (define fd ((iroh-fn 'netlayer-readiness-fd) (iroh-netlayer-handle (iroh-loop-netlayer lp))))
  ;; The netlayer arms the loop at construction, so the readiness fd is always a
  ;; live, pollable handle (a non-blocking socketpair end). A negative fd or an fd
  ;; rktio cannot register is a broken invariant, not a transient state — so it is
  ;; raised, not polled around. Wake every waiter first so no parked pump hangs.
  (define (park-fail why)
    (wake-all! lp)
    (error 'iroh "iroh readiness fd ~a ~a; the loop parks on the fd, it never polls" fd why))
  (when (< fd 0) (park-fail "is not a valid descriptor"))
  (let loop ()
    (cond
      [(iroh-loop-stop? lp) (void)]
      [(not (loop-drain! lp)) (wake-all! lp)] ; endpoint faulted: wake waiters and exit
      [else
       ;; Drain first, then re-arm the fd readiness so a record enqueued during
       ;; the drain still leaves the fd readable and posts the semaphore at once.
       ;; rktio re-arms the semaphore on each call; it stays #f only for an fd it
       ;; cannot poll, which the invariant above rules out.
       (define sema (unsafe-file-descriptor->semaphore fd 'read))
       (unless sema (park-fail "cannot be registered for polling"))
       (sync sema (semaphore-peek-evt (iroh-loop-stop-sema lp)))
       (loop)]))
  (unsafe-file-descriptor->semaphore fd 'remove))

(define (set? events bit) (not (= 0 (bitwise-and events bit))))

(define (dispatch! lp subject events)
  (cond
    [(set? events IROH-EV-ACCEPT)
     (semaphore-post (iroh-loop-accept-sema lp))]
    [(set? events IROH-EV-CONNECT)
     (define result
       (with-handlers ([exn? (lambda (e) (cons 'error e))])
         (cons 'ok (iroh-netlayer-finish-connect (iroh-loop-netlayer lp) subject))))
     (define w (hash-ref (iroh-loop-dials lp) subject #f))
     (hash-remove! (iroh-loop-dials lp) subject)
     (cond
       [(or (not w) (dial-waiter-abandoned? w))
        (when (eq? (car result) 'ok) ((iroh-fn 'conn-release) (cdr result)))]
       [else
        (set-box! (dial-waiter-result w) result)
        (semaphore-post (dial-waiter-sema w))])]
    [else
     (define w (hash-ref (iroh-loop-conns lp) subject #f))
     (when w ; a record for an already-released connection has no waiter
       (when (set? events IROH-EV-CLOSED) (set-conn-waiters-closed?! w #t))
       (when (or (set? events IROH-EV-READABLE) (set? events IROH-EV-CLOSED))
         (semaphore-post (conn-waiters-readable w)))
       (when (or (set? events IROH-EV-WRITABLE) (set? events IROH-EV-CLOSED))
         (semaphore-post (conn-waiters-writable w))))]))

;; ── the iroh `async-transport` ────────────────────────────────────────────────
;; Wrap a loop-driven iroh connection as a core transport. It moves raw bytes
;; through the non-blocking try-read / try-write — exactly the shape the TCP port
;; transport uses, since the frame unit is identical; the readiness loop, not a
;; parked read, decides when bytes are available. `owns-loop?` marks the dialer's
;; pump, which minted its own netlayer and loop and tears both down on close; an
;; accepted link borrows the server's loop and netlayer, so it passes #f.
(define (iroh-loop-transport lp conn owned-netlayer owns-loop?)
  (define w (hash-ref (iroh-loop-conns lp) (conn-key conn)))
  (define read-buf (malloc READ-CHUNK 'atomic-interior))
  (async-transport
   ;; write-frame!: non-blocking try-write, re-arming on the next writable edge
   ;; when the sidecar has no outbound room. A non-negative return may admit only
   ;; a prefix, so advance by the reported byte count and retry the tail.
   (lambda (frame)
     (define fbuf (pin-immobile frame))
     (define frame-len (bytes-length frame))
     (let loop ([offset 0])
       (when (< offset frame-len)
         (define-values (rc n)
           ((iroh-fn 'conn-try-write)
            conn
            (ptr-add fbuf offset)
            (- frame-len offset)))
         (cond
           [(= rc OK)
            (when (= n 0)
              (raise-pancake 'iroh ERR-IO "iroh try-write admitted zero bytes for a non-empty tail"))
            (loop (+ offset n))]
           [(= rc WOULD-BLOCK)
            (if (conn-waiters-closed? w)
                (raise-pancake 'iroh ERR-CLOSED "connection closed while writing")
                (begin (semaphore-wait (conn-waiters-writable w)) (loop offset)))]
           [else (check/iroh rc)])))
     (void))
   void ; the sidecar owns admitted bytes; nothing buffered here to flush
   ;; read-some!: drain whatever bytes are buffered, then park on this
   ;; connection's readability together with the pump's wake event — never a
   ;; wire read. `closed?` (or an ERR-CLOSED return) is a clean end of stream;
   ;; 'woke means the pump should re-check its predicate first.
   (lambda (wake-evt)
     (let loop ()
       (define-values (rc n) ((iroh-fn 'conn-try-read) conn read-buf READ-CHUNK))
       (cond
         [(= rc OK) (bytes<-c read-buf n)]
         [(= rc WOULD-BLOCK)
          (cond
            [(conn-waiters-closed? w) eof]
            [else
             (define ready (sync (conn-waiters-readable w) wake-evt))
             ;; Same rule as TCP port-transport: bytes beat wake. A posted
             ;; progress evt can win `sync` while a try-read would succeed.
             (define-values (rc2 n2) ((iroh-fn 'conn-try-read) conn read-buf READ-CHUNK))
             (cond
               [(= rc2 OK) (bytes<-c read-buf n2)]
               [(= rc2 WOULD-BLOCK)
                (if (eq? ready wake-evt) 'woke (loop))]
               [(= rc2 ERR-CLOSED) eof]
               [else (check/iroh rc2)])])]
         [(= rc ERR-CLOSED) eof]
         [else (check/iroh rc)])))
   ;; close!: drop the routing entry (waking any parked waiter), release the
   ;; connection, and — for the dialer's owned loop — stop the loop and release
   ;; the ephemeral netlayer, in that order, so no foreign call touches the
   ;; endpoint after it is freed. Idempotent through a `closed?` guard and the
   ;; shared `released?` box (loop-stop! may already have released the handle).
   (let ([closed? (box #f)])
     (lambda ()
       (unless (unbox closed?)
         (set-box! closed? #t)
         (loop-unregister! lp conn)
         (release-conn-once! w)
         (when owns-loop?
           (loop-stop! lp)
           (when owned-netlayer
             (iroh-netlayer-close/release! owned-netlayer))))))))

;; ── dial ─────────────────────────────────────────────────────────────────────
;; The iroh dial behind the core's `connect`: take an endpoint id and
;; direct-address hints, complete the keyed OCapN handshake over the
;; encrypted-QUIC transport, and return a ready `connection`. The local endpoint
;; is ephemeral (a fresh key) and driven by its own readiness loop, both released
;; with the connection. `reachability` is an IROH-REACH-* posture, supplied by
;; `connect`.
;; The fresh host's session key and its node identity are one and the same
;; seed, so the connection's wire identity stays coherent, a handoff this host
;; later redeems signs its `desc:handoff-receive` with the very key the gifter
;; recorded, exactly as `dial-parsed-locator`'s TCP arm does. Delegates to the
;; node-keyed dial with a fresh host rather than keying the session
;; independently of the host it builds.
;; Discovery-posture dial retry (ADR-0082): lockstep with PANCAKE_DISCOVERY_DIAL_*.
(define DISCOVERY-DIAL-RETRY-S (/ DISCOVERY-DIAL-RETRY-MS 1000.0))

;; Dial, retrying only under a propagating-discovery posture (DISCOVERY and
;; DISCOVERY-NO-RELAY) while it resolves the partner by id. A dial-by-id can fail
;; with "no addressing information" until the exporter's pkarr record propagates
;; to the n0 resolver (seconds, variable); every other posture dials once
;; (Direct's addresses are in hand, local_discovery resolves instantly). Mirrors
;; the TS `dialResolving` and the Zig `iroh-reachability` driver.
(define (dial-resolving lp node-id direct-addresses retry?)
  (let loop ([attempt 1])
    (define result
      ;; Let a break through rather than absorbing it into a retry: the retry
      ;; loop sleeps for seconds under discovery, so catching exn:break here
      ;; would make the dial uninterruptible — the same defect the convert-to-
      ;; broken sites fixed. Only a non-break failure is a retry candidate.
      ;; ADR-0082: only transient dial faults (ERR-IO) are retried.
      (with-handlers ([(lambda (e) (not (exn:break? e)))
                       (lambda (e)
                         (define code
                           (cond [(exn:fail:pancake? e) (exn:fail:pancake-code e)]
                                 [else #f]))
                         (if (and retry?
                                  (eqv? code ERR-IO)
                                  (< attempt DISCOVERY-DIAL-MAX-ATTEMPTS))
                             'retry
                             (raise e)))])
        (loop-dial! lp node-id direct-addresses)))
    (if (eq? result 'retry)
        (begin (sleep DISCOVERY-DIAL-RETRY-S) (loop (add1 attempt)))
        result)))

;; The node-keyed iroh dial behind a handoff redeem: dial the exporter
;; endpoint and bring the connection up under host `m` rather than a fresh
;; host, so the redeemed capability and any further handoff it triggers share
;; the recipient's one identity, handoff router, and connection table
;; (ADR-0009/ADR-0100), the iroh sibling of `dial-parsed-locator`'s TCP arm.
;; The core's `dial-exporter` loads it lazily for an iroh give. The keyed
;; handshake is the host's (`establish-dialed-locator-session` signs it under
;; the host identity and drives it byte-fed over this transport), and
;; `handshake-timeout-ms` bounds it at `HANDSHAKE-TIMEOUT-MS` by default. The
;; bound covers only the handshake over an established QUIC connection, never
;; the dial-by-id resolution before it: `dial-resolving` owns that wait and its
;; discovery retries, so a slow n0 lookup is not charged to the handshake.
;; ── raw byte channels ────────────────────────────────────────────────────────
;; An iroh connection with nothing running over it: raw bytes in, raw bytes out,
;; and no CapTP handshake. Two consumers need exactly that. A byte-transparent
;; relay pipes the bytes between its legs and keys nothing itself (ADR-0086),
;; and a foreign CapTP — a Spritely Goblins vat, running its own protocol over a
;; netlayer written for it — frames those bytes its own way. Neither wants the
;; native driver listener to bring up CapTP on its behalf.
;;
;; The shape is `byte-channel`: `read` answers the next chunk or eof, `write`
;; sends one by admitting bounded prefixes and waiting only when the sidecar has
;; no outbound room, and `close!` tears the connection down.

;; Wrap a loop-driven transport as a byte channel. `read-some!` parks on the
;; connection's readability with a never-ready wake event, so it only ever
;; answers bytes or eof, never 'woke. `verified-remote` is what QUIC proved
;; about the far end of `conn`, read here because this is where the connection
;; becomes something a consumer holds.
(define (channel-over-transport transport verified-remote)
  (byte-channel
   (lambda () ((async-transport-read-some! transport) never-evt))
   (lambda (data) ((async-transport-write-frame! transport) data))
   (lambda () ((async-transport-close! transport)))
   verified-remote))

;; The endpoint id QUIC verified for the far end of `conn` during the TLS
;; handshake, as the lowercase-hex designator an `iroh` locator carries, or #f
;; when the sidecar could not read it. Accepted and dialed connections both
;; carry one: QUIC authenticates the remote either way, so an accept can name
;; its partner exactly as a dial can.
;;
;; A connection whose proof cannot be read answers #f rather than raising: the
;; bytes still move, and a consumer that pipes them (a relay) never asks. What
;; #f costs is attribution — a consumer weighing a partner's claim has nothing
;; to weigh it against and must call the partner unproven.
(define (conn-verified-remote conn)
  (define buf (make-bytes 64)) ; an endpoint id is 64 lowercase-hex bytes
  (define-values (rc len) ((iroh-fn 'conn-remote-node-id) conn buf 64))
  (and (= rc OK) (bytes->string/utf-8 (subbytes buf 0 len))))

;; Should a dial under this posture retry while the partner's record propagates?
(define (propagating-discovery? reachability)
  (or (= reachability IROH-REACH-DISCOVERY)
      (= reachability IROH-REACH-DISCOVERY-NO-RELAY)))

;; Dial an endpoint by id (plus direct-address hints, which a discovery posture
;; may leave empty) and answer the raw byte channel over it. `owned-netlayer` is
;; the endpoint the channel's close should tear down, or #f when the caller keeps
;; it and serves other connections from the same loop.
(define (dial-channel-over lp owned-netlayer node-id direct-addresses reachability)
  (define conn (dial-resolving lp node-id direct-addresses (propagating-discovery? reachability)))
  (loop-register! lp conn)
  (channel-over-transport (iroh-loop-transport lp conn owned-netlayer (and owned-netlayer #t))
                          (conn-verified-remote conn)))

;; Dial an iroh `ocapn://` locator to a byte channel, completing NO CapTP
;; handshake: the relay only pipes bytes, and the two ends key the session end to
;; end. This is the Racket sibling of the TypeScript `dialLocatorForRelay` and the
;; Python `dial_locator_for_relay`; the iroh readiness compose lives in each
;; binding over the same C-ABI conn and readiness primitives the serve loop
;; drives. The direct-address hint reaches the conformance host over loopback
;; (Direct); a deployment relay resolves node ids by discovery.
;;
;; The local endpoint is ephemeral and released with the channel, which suits a
;; caller that only ever dials, holds no name of its own, and wants one
;; connection. A caller a partner also reaches dials from its own endpoint with
;; `iroh-endpoint-dial` instead, so both directions carry the one identity it
;; publishes.
(define (dial-locator-for-relay locator reachability)
  (define loc (parse-locator locator))
  (unless (string=? (locator-transport loc) TRANSPORT-IROH)
    (error 'dial-locator-for-relay
           "expected an iroh locator, got transport ~a" (locator-transport loc)))
  (define-values (netlayer _seed) (iroh-netlayer-new (make-iroh-config reachability)))
  (define lp (make-iroh-loop netlayer))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (loop-stop! lp) (iroh-netlayer-close/release! netlayer) (raise e))])
    (dial-channel-over lp netlayer
                       (locator-designator loc)
                       (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES "")
                       reachability)))
;; ── the raw byte-channel endpoint ────────────────────────────────────────────
;; One bound iroh endpoint whose partners are raw byte channels, in both
;; directions: it accepts and it dials, and every connection either way rides its
;; one readiness loop and carries its one node id. That symmetry is the point. A
;; consumer a partner can also reach has a name of its own, and a dial from some
;; other endpoint would reach the partner under a key that is not the one it
;; publishes.
;;
;; Nothing runs over the bytes here, which is what a consumer with its own
;; protocol needs: a foreign CapTP — a Spritely Goblins vat, over a netlayer
;; written for it — frames them its own way. The keyed pancake server below is
;; the other consumer, and it is this endpoint plus a CapTP host.
(struct iroh-endpoint (netlayer loop reachability))

;; Bind an iroh endpoint. `reachability` is required, an IROH-REACH-* posture, no
;; default. Optional `seed` is a 32-byte Ed25519 secret, so a caller that also
;; signs something under that key gets one identity for the endpoint and the
;; signature; omit it for a fresh random key.
(define (open-iroh-endpoint config [seed #f])
  (define-values (nl _seed) (iroh-netlayer-new config seed))
  (define e (iroh-endpoint nl (make-iroh-loop nl) (iroh-config-reachability config)))
  ;; Release fallback: a caller that drops the endpoint without closing it still
  ;; gets the readiness loop thread stopped (a live GC root that would otherwise
  ;; pin the whole graph forever) and the endpoint fd released. The loop thread
  ;; roots only the loop, never `e`, so `e` stays collectable and this fires; the
  ;; close is idempotent, so it is harmless after an explicit one.
  (register-finalizer e (lambda (q) (iroh-endpoint-close! q)))
  e)

;; This endpoint's id: the dialable designator an `iroh` locator carries.
(define (iroh-endpoint-node-id e)
  (iroh-netlayer-node-id (iroh-endpoint-netlayer e)))

;; This endpoint's direct-address hints (comma-separated), the dialable
;; addresses with no relay, valid on loopback/LAN.
(define (iroh-endpoint-direct-addresses e)
  (iroh-netlayer-direct-addresses (iroh-endpoint-netlayer e)))

;; Claim the next accepted connection and serve it from the endpoint's loop, the
;; one every other connection rides. Parks on the accept gate when none is
;; pending, and raises once the endpoint is closed. `who` names the caller in
;; that raise, so a closed keyed server and a closed byte endpoint each report
;; themselves. This is the transport under both accept surfaces. Answers the
;; transport and the partner id QUIC verified for it, because the connection is
;; the only thing that holds that proof and it is gone once the raw handle is.
(define (accept-loop-transport who e)
  (define nl (iroh-endpoint-netlayer e))
  (define lp (iroh-endpoint-loop e))
  (let loop ()
    (define-values (rc conn) ((iroh-fn 'netlayer-try-accept) (iroh-netlayer-handle nl)))
    (cond
      [(= rc OK)
       (loop-register! lp conn)
       (values (iroh-loop-transport lp conn #f #f) (conn-verified-remote conn))]
      [(= rc WOULD-BLOCK)
       (if (iroh-loop-accept-closed? lp)
           (raise-pancake who ERR-CLOSED "server closed")
           (begin (semaphore-wait (iroh-loop-accept-sema lp)) (loop)))]
      [else (check/iroh rc)])))

;; Park until a partner arrives, then answer its byte channel. Raises once the
;; endpoint is closed.
(define (iroh-endpoint-accept e)
  (define-values (transport verified-remote)
    (accept-loop-transport 'iroh-endpoint-accept e))
  (channel-over-transport transport verified-remote))

;; Dial a partner by endpoint id (plus direct-address hints, which a discovery
;; posture may leave empty) from this endpoint, and answer its byte channel. The
;; partner's QUIC handshake therefore authenticates this endpoint's own node id,
;; the same one `iroh-endpoint-node-id` publishes. Closing the channel closes
;; that one connection and leaves the endpoint serving.
(define (iroh-endpoint-dial e node-id direct-addresses)
  (dial-channel-over (iroh-endpoint-loop e) #f node-id direct-addresses
                     (iroh-endpoint-reachability e)))

;; Stop accepting, stop the readiness loop (joining its thread and releasing any
;; still-registered connection), and release the endpoint. Idempotent.
(define (iroh-endpoint-close! e)
  (loop-stop! (iroh-endpoint-loop e))
  (iroh-netlayer-close/release! (iroh-endpoint-netlayer e)))

;; ── host ─────────────────────────────────────────────────────────────────────
;; A keyed pancake server: the byte endpoint above, plus the one CapTP host every
;; session it accepts shares — that host's retained identity and live-session
;; directory — the iroh sibling of the TCP `server`'s host. The host owns an
;; `engine.Node` (sans-io router). The gifter half of a three-party handoff dials
;; the exporter under this same host (`connect` with `#:host`) so a published
;; host-giftable and the introducer it returns share one host (ADR-0009 /
;; ADR-0079).
;; A driver-owned keyed iroh server. The supplied Host is transferred into
;; the native loop; there is no second CapTP admission implementation.
(struct iroh-server (node-id host loop-server))

(define (listen-iroh config [seed #f] #:host [host #f])
  (define seed*
    (or seed (and host (host-seed host)) (crypto-random-bytes 32)))
  (unless (= (bytes-length seed*) 32)
    (raise-pancake 'listen-iroh ERR-INVALID-ARGUMENT
                   "the iroh seed must be 32 bytes"))
  (when (and host seed (not (bytes=? seed (host-seed host))))
    (raise-pancake 'listen-iroh ERR-INVALID-ARGUMENT
                   "the seed conflicts with the supplied Host"))
  (define-values (lp owns-loop?)
    (if (and host (host-loop-of host))
        (values (host-loop-of host) #f)
        (values (open-driver-loop #:host host #:seed seed*) #t)))
  (define listener #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (when listener (loop-listener-close! lp listener))
                     (when owns-loop? (driver-loop-abort! lp))
                     (raise e))])
    (iroh-adopt-loop! lp config #:seed seed*)
    (set! listener
          (loop-listen! lp TRANSPORT-IROH (designator-from-seed seed*)))
    (define initial (loop-listener-locator lp listener))
    (define node-id (locator-designator initial))
    (loop-listener-select! lp listener)
    (driver-loop-start! lp)
    (iroh-server node-id (driver-loop-host lp)
                 (make-loop-server lp listener node-id #f (not host)))))


(define (iroh-server-direct-addresses s)
  (define loc (loop-server-locator (iroh-server-loop-server s)))
  (hash-ref (locator-hints loc) HINT-DIRECT-ADDRESSES ""))
(define (iroh-server-accept s)
  (loop-server-accept (iroh-server-loop-server s)))
(define (iroh-server-close! s)
  (loop-server-close! (iroh-server-loop-server s)))
