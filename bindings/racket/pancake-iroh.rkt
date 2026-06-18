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
;; `pancake.rkt` exports; the core calls come from there. Everything above the
;; pump — vat, conn-* verbs, events — is the core's; only the transport differs.
;;
;; `connect` in the core dials an iroh locator by loading this module lazily, so a
;; TCP-only program never needs the iroh library. Hosting (`listen-iroh` and the
;; `iroh-server-*` surface) is reached through this module directly.

(require ffi/unsafe
         ffi/unsafe/port
         "private/constants.rkt"
         "private/ffi-iroh.rkt"
         "pancake.rkt")

(provide connect-iroh
         listen-iroh
         IROH-REACH-DIRECT IROH-REACH-DISCOVERY IROH-REACH-DISCOVERY-NO-RELAY IROH-REACH-LOCAL-DISCOVERY
         iroh-server? iroh-server-node-id iroh-server-direct-addresses
         iroh-server-uri iroh-server-accept iroh-server-close!)

;; Reachability posture — REQUIRED on every public iroh constructor, with NO
;; default: a peer states how it is reachable, the binding never guesses. The
;; lazy iroh ABI loader behind `iroh-fn` lives in `private/ffi-iroh.rkt`.
(define IROH-REACH-DIRECT 0)             ; dial by id + direct-address hints; relay-less, no discovery
(define IROH-REACH-DISCOVERY 1)          ; n0 relays + DNS discovery; dial by id alone
(define IROH-REACH-DISCOVERY-NO-RELAY 2) ; DNS discovery, no relays
(define IROH-REACH-LOCAL-DISCOVERY 3)    ; in-process address book; tests/same-process

;; ── netlayer FFI wrappers ─────────────────────────────────────────────────────
;; `reachability` is required — an IROH-REACH-* posture, no default.
(define (iroh-netlayer-new reachability)
  (define-values (rc h) ((iroh-fn 'netlayer-new) #f 0 reachability)) ; #f/0 secret seed = a fresh random key
  (check rc)
  h)

(define (iroh-netlayer-node-id h)
  (define buf (make-bytes 64)) ; an endpoint id is 64 lowercase-hex bytes
  (define-values (rc len) ((iroh-fn 'node-id) h buf 64))
  (check rc)
  (bytes->string/utf-8 (subbytes buf 0 len)))

(define (iroh-netlayer-direct-addresses h)
  ;; A buffer too small is ERR-INVALID-ARGUMENT; grow until the comma-separated
  ;; hint string fits (loopback hints are short, but be safe).
  (let loop ([cap 256])
    (define buf (make-bytes cap))
    (define-values (rc len) ((iroh-fn 'direct-addrs) h buf cap))
    (cond
      [(and (= rc ERR-INVALID-ARGUMENT) (< cap (* 64 1024))) (loop (* cap 4))]
      [else (check rc) (bytes->string/utf-8 (subbytes buf 0 len))])))

;; Dial a partner non-blockingly: the dial itself parks (it is #:blocking?), but
;; the returned connection is driven by the netlayer's readiness loop, so its
;; reads and writes never park a thread. Pin the borrowed inputs in immobile
;; memory — the call may run while the GC moves Racket-managed blocks.
(define (iroh-netlayer-try-connect h node-id hints)
  (define nb (string->bytes/utf-8 node-id))
  (define hb (string->bytes/utf-8 hints))
  (define nbuf (malloc (max (bytes-length nb) 1) 'atomic-interior)) (memcpy nbuf nb (bytes-length nb))
  (define hbuf (malloc (max (bytes-length hb) 1) 'atomic-interior)) (memcpy hbuf hb (bytes-length hb))
  (define-values (rc conn) ((iroh-fn 'try-connect) h nbuf (bytes-length nb) hbuf (bytes-length hb)))
  (check rc)
  conn)

(define (iroh-netlayer-close! h) ((iroh-fn 'netlayer-close) h))
(define (iroh-netlayer-release! h) ((iroh-fn 'netlayer-release) h))

;; ── the iroh readiness loop (ADR-0057) ────────────────────────────────────────
;; The Racket sibling of the Deno binding's `IrohLoop`, the Python binding's
;; `_IrohLoop`, and the Zig resident's `LoopHost`: one green thread multiplexes
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
;; not lost), and a `closed?` flag the loop raises on a close record.
(struct conn-waiters (readable writable [closed? #:mutable]))

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
             (conn-waiters (make-semaphore 0) (make-semaphore 0) #f)))

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
;; pumps unwind. Posting the stop event wakes the thread from its fd park at once;
;; it sees `stop?` and exits, deregistering the fd. The caller releases the
;; netlayer after, with no foreign call still touching it.
(define (loop-stop! lp)
  (unless (iroh-loop-stop? lp)
    (set-iroh-loop-stop?! lp #t)
    (semaphore-post (iroh-loop-stop-sema lp))
    (wake-all! lp)
    (define t (iroh-loop-thread lp))
    (when t (thread-wait t))))

;; Drain the ready-queue in batches until a short count, posting each record to
;; its waiter. Returns #f when the endpoint faulted (a negative drain), so the
;; loop can wind down. A `drain-ready` call also clears the fd's wakeup bytes.
(define (loop-drain! lp)
  (define buf (iroh-loop-buf lp))
  (let drain ()
    (define n ((iroh-fn 'drain-ready) (iroh-loop-netlayer lp) buf DRAIN-READY-CAP))
    (cond
      [(< n 0) #f]
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
  (define fd ((iroh-fn 'readiness-fd) (iroh-loop-netlayer lp)))
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

(define (dispatch! lp conn-ptr events)
  (cond
    [(set? events IROH-EV-ACCEPT)
     (semaphore-post (iroh-loop-accept-sema lp))]
    [else
     (define w (hash-ref (iroh-loop-conns lp) (cast conn-ptr _pointer _uintptr) #f))
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
     (define fbuf (malloc (max (bytes-length frame) 1) 'atomic-interior))
     (memcpy fbuf frame (bytes-length frame))
     (let loop ()
       (define n ((iroh-fn 'conn-try-write) conn fbuf (bytes-length frame)))
       (cond
         [(>= n 0) (void)]
         [(= n WOULD-BLOCK)
          (if (conn-waiters-closed? w)
              (error 'iroh "connection closed while writing")
              (begin (semaphore-wait (conn-waiters-writable w)) (loop)))]
         [else (check n)])))
   void ; each frame is its own try-write; nothing buffered here to flush
   ;; fill-inbox!: drain whatever bytes are buffered, then park on this
   ;; connection's readability — never a wire read. `closed?` (or an ERR-CLOSED
   ;; return) is a clean end of stream.
   (lambda ()
     (let loop ()
       (define n ((iroh-fn 'conn-try-read) conn read-buf READ-CHUNK))
       (cond
         [(> n 0) (bytes<-c read-buf n)]
         [(= n WOULD-BLOCK)
          (if (conn-waiters-closed? w)
              eof
              (begin (semaphore-wait (conn-waiters-readable w)) (loop)))]
         [(= n ERR-CLOSED) eof]
         [else (check n)])))
   ;; close!: drop the routing entry (waking any parked waiter), release the
   ;; connection, and — for the dialer's owned loop — stop the loop and release
   ;; the ephemeral netlayer, in that order, so no foreign call touches the
   ;; endpoint after it is freed.
   (lambda ()
     (loop-unregister! lp conn)
     ((iroh-fn 'conn-release) conn)
     (when owns-loop?
       (loop-stop! lp)
       (when owned-netlayer
         (iroh-netlayer-close! owned-netlayer)
         (iroh-netlayer-release! owned-netlayer))))))

;; ── dial ─────────────────────────────────────────────────────────────────────
;; The iroh dial behind the core's `connect`: take an endpoint id and
;; direct-address hints, complete the keyed OCapN handshake over the
;; encrypted-QUIC transport, and return a ready `connection`. The local endpoint
;; is ephemeral (a fresh key) and driven by its own readiness loop, both released
;; with the connection. `reachability` is an IROH-REACH-* posture, supplied by
;; `connect`.
(define (connect-iroh node-id direct-addresses reachability)
  (define netlayer (iroh-netlayer-new reachability))
  (define lp (make-iroh-loop netlayer))
  (define conn
    (with-handlers ([(lambda (_) #t)
                     (lambda (e) (loop-stop! lp) (iroh-netlayer-release! netlayer) (raise e))])
      (iroh-netlayer-try-connect netlayer node-id direct-addresses)))
  (loop-register! lp conn)
  (define peer (make-peer))
  (define ac (async-connection/transport peer (iroh-loop-transport lp conn netlayer #t)))
  ;; A dialer signs an empty designator (its identity is the session key),
  ;; matching the Zig driver; the pump owns the ephemeral netlayer and loop.
  (open-keyed-session! ac "" #:transport "iroh")
  (connection ac (make-vat #:peer peer) (make-fresh-machine)))

;; ── host ─────────────────────────────────────────────────────────────────────
(struct iroh-server (netlayer node-id loop))

;; Bind a fresh ephemeral iroh endpoint and return a server that accepts partners
;; on it, all driven by one readiness loop. Read its dialable URI with
;; `iroh-server-uri` and pass that to a partner's `connect`. `reachability` is
;; required — an IROH-REACH-* posture, no default.
(define (listen-iroh reachability)
  (define nl (iroh-netlayer-new reachability))
  (define lp (make-iroh-loop nl))
  (iroh-server nl (iroh-netlayer-node-id nl) lp))

;; This endpoint's direct-address hints (comma-separated) — the dialable
;; addresses with no relay, valid on loopback/LAN.
(define (iroh-server-direct-addresses s) (iroh-netlayer-direct-addresses (iroh-server-netlayer s)))

;; The `ocapn://<nodeid>.iroh?direct-addresses=…` URI a partner dials, rendered
;; through the core locator grammar.
(define (iroh-server-uri s)
  (define addrs (iroh-server-direct-addresses s))
  (format-peer-uri "iroh" (iroh-server-node-id s)
                   (if (= 0 (string-length addrs)) (hash) (hash "direct-addresses" addrs))))

;; Claim the next partner, complete the responder handshake (signing the server's
;; endpoint id as the locator designator), and return a ready connection — served
;; from the same loop as every other accepted connection. Parks on the loop's
;; accept gate when none is pending; raises once the server is closed.
(define (iroh-server-accept s)
  (define lp (iroh-server-loop s))
  (let loop ()
    (define-values (rc conn) ((iroh-fn 'try-accept) (iroh-server-netlayer s)))
    (cond
      [(= rc OK)
       (loop-register! lp conn)
       (define peer (make-peer))
       (define ac (async-connection/transport peer (iroh-loop-transport lp conn #f #f)))
       (open-keyed-session! ac (iroh-server-node-id s) #:transport "iroh")
       (connection ac (make-vat #:peer peer) (make-fresh-machine))]
      [(= rc WOULD-BLOCK)
       (if (iroh-loop-accept-closed? lp)
           (error 'iroh-server-accept "server closed")
           (begin (semaphore-wait (iroh-loop-accept-sema lp)) (loop)))]
      [else (check rc)])))

;; Stop accepting, stop the readiness loop (joining its thread), and release the
;; server's endpoint. Accepted connections are unaffected until their own
;; `connection-close!`.
(define (iroh-server-close! s)
  (loop-stop! (iroh-server-loop s))
  (iroh-netlayer-close! (iroh-server-netlayer s))
  (iroh-netlayer-release! (iroh-server-netlayer s)))
