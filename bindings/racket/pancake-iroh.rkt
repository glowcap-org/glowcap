#lang racket/base
;; pancake-iroh — the iroh transport companion for the pancake Racket binding.
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
;; TCP-only program never needs the iroh library. Hosting (`listen-iroh` and the
;; `iroh-server-*` surface) is reached through this module directly.

(require ffi/unsafe
         ffi/unsafe/port
         racket/random
         "private/constants.rkt"
         "private/ffi-iroh.rkt"
         "private/seam.rkt")

(provide listen-iroh
         IROH-REACH-DIRECT IROH-REACH-DISCOVERY IROH-REACH-DISCOVERY-NO-RELAY IROH-REACH-LOCAL-DISCOVERY
         iroh-server-node-id iroh-server-direct-addresses
         iroh-server-host iroh-server-accept iroh-server-close!)

;; Reachability posture, REQUIRED on every public iroh constructor, with NO
;; default: a peer states how it is reachable, the binding never guesses. The
;; lazy iroh ABI loader behind `iroh-fn` lives in `private/ffi-iroh.rkt`.
(define IROH-REACH-DIRECT 0)             ; dial by id + direct-address hints; relay-less, no discovery
(define IROH-REACH-DISCOVERY 1)          ; n0 relays + DNS discovery; dial by id alone
(define IROH-REACH-DISCOVERY-NO-RELAY 2) ; DNS discovery, no relays
(define IROH-REACH-LOCAL-DISCOVERY 3)    ; in-process address book; tests/same-process

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
(define (iroh-netlayer-new reachability [seed #f])
  (define seed* (or seed (crypto-random-bytes 32)))
  (define-values (rc h)
    ((iroh-fn 'netlayer-new) (pin-immobile seed*) (bytes-length seed*) reachability))
  (check/iroh rc)
  (values (iroh-netlayer h) seed*))

(define (iroh-netlayer-node-id nl)
  (define buf (make-bytes 64)) ; an endpoint id is 64 lowercase-hex bytes
  (define-values (rc len) ((iroh-fn 'node-id) (iroh-netlayer-handle nl) buf 64))
  (check/iroh rc)
  (bytes->string/utf-8 (subbytes buf 0 len)))

(define (iroh-netlayer-direct-addresses nl)
  ;; A buffer too small is ERR-BUFFER-TOO-SMALL; grow until the comma-separated
  ;; hint string fits (loopback hints are short, but be safe).
  (let loop ([cap 256])
    (define buf (make-bytes cap))
    (define-values (rc len) ((iroh-fn 'direct-addrs) (iroh-netlayer-handle nl) buf cap))
    (cond
      [(and (= rc ERR-BUFFER-TOO-SMALL) (< cap (* 64 1024))) (loop (* cap 4))]
      [else (check/iroh rc) (bytes->string/utf-8 (subbytes buf 0 len))])))

;; Dial a partner non-blockingly: the dial itself parks (it is #:blocking?), but
;; the returned connection is driven by the netlayer's readiness loop, so its
;; reads and writes never park a thread. Pin the borrowed inputs in immobile
;; memory, the call may run while the GC moves Racket-managed blocks.
(define (iroh-netlayer-try-connect nl node-id hints)
  (define nb (string->bytes/utf-8 node-id))
  (define hb (string->bytes/utf-8 hints))
  (define nbuf (pin-immobile nb))
  (define hbuf (pin-immobile hb))
  (define-values (rc conn) ((iroh-fn 'try-connect) (iroh-netlayer-handle nl) nbuf (bytes-length nb) hbuf (bytes-length hb)))
  (check/iroh rc)
  conn)

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

;; One readiness loop per netlayer: the netlayer it watches, the address→waiters
;; table, the accept gate (posted on each accept record), a stop event the loop
;; thread syncs alongside the fd so a close wakes it at once, and the dedicated
;; readiness thread. `buf` is the reused record array the loop drains into.
(struct iroh-loop (netlayer conns accept-sema stop-sema [accept-closed? #:mutable] [stop? #:mutable] [thread #:mutable] buf))

;; A connection handle's address, the stable key both `try-connect`/`try-accept`
;; and the `drain-ready` records spell it by.
(define (conn-key conn) (cast conn _pointer _uintptr))

;; Spawn the netlayer's readiness thread. The loop is already armed (the netlayer
;; arms it at construction), so this only stands up the fd-parking thread.
(define (make-iroh-loop netlayer)
  (define lp (iroh-loop netlayer (make-hash) (make-semaphore 0) (make-semaphore 0) #f #f #f
                        (malloc _PancakeIrohReadyEvent DRAIN-READY-CAP 'atomic-interior)))
  (set-iroh-loop-thread! lp (thread (lambda () (loop-run lp))))
  lp)

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
    (define t (iroh-loop-thread lp))
    (when t (thread-wait t))))

;; Drain the ready-queue in batches until a short count, posting each record to
;; its waiter. Returns #f when the endpoint faulted (a negative drain), so the
;; loop can wind down. A `drain-ready` call also clears the fd's wakeup bytes.
(define (loop-drain! lp)
  (define buf (iroh-loop-buf lp))
  (let drain ()
    (define-values (rc n) ((iroh-fn 'drain-ready) (iroh-netlayer-handle (iroh-loop-netlayer lp)) buf DRAIN-READY-CAP))
    (cond
      [(not (= rc OK)) #f]
      [(= n 0) #t]
      [else
       (for ([i (in-range n)])
         (define rec (ptr-ref buf _PancakeIrohReadyEvent i))
         (dispatch! lp (PancakeIrohReadyEvent-conn rec) (PancakeIrohReadyEvent-events rec)))
       (if (= n DRAIN-READY-CAP) (drain) #t)])))

;; The dedicated readiness thread: park on the netlayer's readiness fd, and on
;; each wake drain the records and post them to the waiting connections. The park
;; is native — `unsafe-file-descriptor->semaphore` registers the fd with the
;; place's poller and posts the semaphore when it is readable — so the thread
;; truly sleeps without freezing the place.
(define (loop-run lp)
  (define fd ((iroh-fn 'readiness-fd) (iroh-netlayer-handle (iroh-loop-netlayer lp))))
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

(define (dispatch! lp session-ptr events)
  (cond
    [(set? events IROH-EV-ACCEPT)
     (semaphore-post (iroh-loop-accept-sema lp))]
    [else
     (define w (hash-ref (iroh-loop-conns lp) (cast session-ptr _pointer _uintptr) #f))
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
   ;; write-frame!: non-blocking try-write, re-arming on the next writable edge if
   ;; the sidecar buffer is full. try-write is all-or-nothing: a non-negative
   ;; return means the whole frame went.
   (lambda (frame)
     (define fbuf (pin-immobile frame))
     (let loop ()
       (define-values (rc n) ((iroh-fn 'conn-try-write) conn fbuf (bytes-length frame)))
       (cond
         [(= rc OK) (void)]
         [(= rc WOULD-BLOCK)
          (if (conn-waiters-closed? w)
              (raise-pancake 'iroh ERR-CLOSED "connection closed while writing")
              (begin (semaphore-wait (conn-waiters-writable w)) (loop)))]
         [else (check/iroh rc)])))
   void ; each frame is its own try-write; nothing buffered here to flush
   ;; fill-inbox!: drain whatever bytes are buffered, then park on this
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
             (if (eq? ready wake-evt) 'woke (loop))])]
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
;; The discovery-posture dial retry budget: how long pkarr propagation is given
;; before each retry, and how many attempts (~72s total, covering n0 DNS/pkarr
;; propagation). Matches the TS `dialResolving` budget.
(define DISCOVERY-DIAL-RETRY-S 3.0)
(define DISCOVERY-DIAL-MAX-ATTEMPTS 24)

;; Dial, retrying only under a propagating-discovery posture (DISCOVERY and
;; DISCOVERY-NO-RELAY) while it resolves the partner by id. A dial-by-id can fail
;; with "no addressing information" until the exporter's pkarr record propagates
;; to the n0 resolver (seconds, variable); every other posture dials once
;; (Direct's addresses are in hand, local_discovery resolves instantly). Mirrors
;; the TS `dialResolving` and the Zig `iroh-reachability` driver.
(define (dial-resolving netlayer node-id direct-addresses retry?)
  (let loop ([attempt 1])
    (define result
      ;; Let a break through rather than absorbing it into a retry: the retry
      ;; loop sleeps for seconds under discovery, so catching exn:break here
      ;; would make the dial uninterruptible — the same defect the convert-to-
      ;; broken sites fixed. Only a non-break failure is a retry candidate.
      (with-handlers ([(lambda (e) (not (exn:break? e)))
                       (lambda (e)
                         (if (and retry? (< attempt DISCOVERY-DIAL-MAX-ATTEMPTS))
                             'retry
                             (raise e)))])
        (iroh-netlayer-try-connect netlayer node-id direct-addresses)))
    (if (eq? result 'retry)
        (begin (sleep DISCOVERY-DIAL-RETRY-S) (loop (add1 attempt)))
        result)))

;; The node-keyed iroh dial behind a handoff redeem: dial the exporter
;; endpoint and bring the connection up under host `m` rather than a fresh
;; host, so the redeemed capability and any further handoff it triggers share
;; the recipient's one identity, gift registry, and connection table
;; (ADR-0009/ADR-0056), the iroh sibling of `dial-parsed-locator`'s TCP arm.
;; The core's `dial-exporter` loads it lazily for an iroh give. The keyed
;; handshake is the host's (`establish-dialed-locator-session` signs it under
;; the host identity and drives it byte-fed over this transport).
(define (connect-iroh/node node-id direct-addresses reachability m)
  (define-values (netlayer _) (iroh-netlayer-new reachability))
  (define lp (make-iroh-loop netlayer))
  (define conn
    (with-handlers ([(lambda (_) #t)
                     (lambda (e) (loop-stop! lp) (iroh-netlayer-close/release! netlayer) (raise e))])
      (dial-resolving netlayer node-id direct-addresses
                      (or (= reachability IROH-REACH-DISCOVERY)
                          (= reachability IROH-REACH-DISCOVERY-NO-RELAY)))))
  (loop-register! lp conn)
  (define transport (iroh-loop-transport lp conn netlayer #t))
  (define c
    (with-handlers ([(lambda (_) #t)
                     (lambda (e) ((async-transport-close! transport)) (raise e))])
      (establish-dialed-locator-session m TRANSPORT-IROH node-id transport)))
  ;; Release fallback: the dialer owns its ephemeral netlayer, readiness loop
  ;; thread, and connection. If the caller drops `c` without an explicit
  ;; `session-close!`, run the transport's (idempotent) close lambda — the
  ;; same teardown that stops the loop thread and releases the endpoint fd. The
  ;; loop thread roots only `lp`, never `c` or its `transport`, so `c` stays
  ;; collectable and this fires; the close guard makes it harmless after an
  ;; explicit close. Capturing `transport` (not `c`) keeps the finalizer from
  ;; rooting the very object whose collection triggers it.
  (register-finalizer c (lambda (_) ((async-transport-close! transport))))
  c)

;; ── host ─────────────────────────────────────────────────────────────────────
;; `host` is the one CapTP host shared by every session this server
;; accepts — its retained identity and gift registry — the iroh sibling of the
;; TCP `server`'s host. The host owns an `engine.Node` (sans-io router). The
;; gifter half of a three-party handoff dials the exporter under this same host
;; (`connect` with `#:host`) so a published host-giftable and the introducer it
;; returns share one host (ADR-0009 / ADR-0079).
(struct iroh-server (netlayer node-id loop host))

;; Bind a fresh ephemeral iroh endpoint and return a server that accepts partners
;; on it, all driven by one readiness loop. A partner dials it through the core's
;; `connect` on a `format-peer-uri` of `TRANSPORT-IROH` + `iroh-server-node-id`
;; (plus `HINT-DIRECT-ADDRESSES` from `iroh-server-direct-addresses` when it has
;; no discovery path). `reachability` is required, an IROH-REACH-* posture, no
;; default. Optional `seed` is a 32-byte Ed25519 secret shared by the endpoint
;; and the Host — one identity for designator, session key, and iroh node id
;; (ADR-0075); omit it to draw a fresh random seed for both.
(define (listen-iroh reachability [seed #f])
  (define-values (nl seed*) (iroh-netlayer-new reachability seed))
  (define lp (make-iroh-loop nl))
  (define node-id (iroh-netlayer-node-id nl))
  ;; Same seed as the endpoint — never mint a fresh Host beside a different
  ;; endpoint key (rooms Deno / Zig interop pattern).
  (define m (make-host seed*))
  ;; This host also dials (the gifter side of a handoff), and its dials sign
  ;; the endpoint's own node id so a partner's crossed-hellos table can
  ;; recognize it. Setting the designator alone is not enough — the signing
  ;; key must be the same seed.
  (host-set-self-designator! m node-id)
  (define s (iroh-server nl node-id lp m))
  ;; Release fallback: if the caller drops the server without `iroh-server-close!`,
  ;; the finalizer stops the readiness loop thread (a live GC root that would
  ;; otherwise pin the whole graph forever) and releases the endpoint fd. The loop
  ;; thread roots only `lp`, never `s`, so `s` stays collectable and this fires;
  ;; `iroh-server-close!` is idempotent, so it is harmless after an explicit close.
  (register-finalizer s (lambda (q) (iroh-server-close! q)))
  s)

;; This endpoint's direct-address hints (comma-separated), the dialable
;; addresses with no relay, valid on loopback/LAN.
(define (iroh-server-direct-addresses s) (iroh-netlayer-direct-addresses (iroh-server-netlayer s)))

;; Claim the next partner, complete the responder handshake (signing the server's
;; endpoint id as the locator designator), and return a ready connection — served
;; from the same loop as every other accepted connection. Parks on the loop's
;; accept gate when none is pending; raises once the server is closed.
(define (iroh-server-accept s)
  (define lp (iroh-server-loop s))
  (let loop ()
    (define-values (rc conn) ((iroh-fn 'try-accept) (iroh-netlayer-handle (iroh-server-netlayer s))))
    (cond
      [(= rc OK)
       (define m (iroh-server-host s))
       (loop-register! lp conn)
       ;; The host publishes the host's giftables on the fresh connection as it
       ;; is minted and answers a dialer's pipelined bootstrap fetch the instant
       ;; the session opens; the responder signs the server's own endpoint id
       ;; under the host's one retained identity, exactly as the TCP responder
       ;; does.
       (establish-accepted-session m TRANSPORT-IROH (iroh-server-node-id s)
                                      (iroh-loop-transport lp conn #f #f))]
      [(= rc WOULD-BLOCK)
       (if (iroh-loop-accept-closed? lp)
           (raise-pancake 'iroh-server-accept ERR-CLOSED "server closed")
           (begin (semaphore-wait (iroh-loop-accept-sema lp)) (loop)))]
      [else (check/iroh rc)])))

;; Stop accepting, stop the readiness loop (joining its thread and releasing
;; any still-registered connections), and release the server's endpoint.
(define (iroh-server-close! s)
  (loop-stop! (iroh-server-loop s))
  (iroh-netlayer-close/release! (iroh-server-netlayer s)))

;; Binding-internal dial for `dial-parsed-locator`'s iroh arm. Not part of the
;; application companion surface — loaded only via `(submod … dial)`.
(module* dial #f
  (provide connect-iroh/node))
