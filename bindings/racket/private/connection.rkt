#lang racket/base
;; Internal: the high-level connection surface over the byte-fed host
;; (libpancake_driver, ADR-0072). It owns the `connection` and `server` structs
;; and every `conn-*` application verb (`connect`, `listen`, `accept`,
;; `conn-fetch`, `conn-send`, `conn-tell`, `conn-serve`, …), plus the two
;; things the embedder contract leaves to the binding: the pump — read raw
;; bytes off the transport, hand them to the core's stream delimiter
;; (`pancake_host_conn_feed_bytes`, which owns framing), drain the host's
;; action queue, write what `take_outbound` drains — and the dial executor a
;; DIAL action names
;; (the recipient half of a three-party handoff opens its own socket to the
;; exporter; the posture decision for a hint-less iroh give lives here). The
;; host owns everything else: routing, redemption, gift origination, far vows.
;;
;; THE PUMP. After any top-level host verb, the action queue drains until dry
;; (the one loop rule): a NEED_GIFT_ID draws 32 random bytes on the spot, a
;; FLUSH parks the named connection's encoded outbound on its pending-writes
;; FIFO, and a DIAL parks the executor among the drain's fires. The pops run
;; under the node's reentrant lock (`call-with-node`), so several green
;; threads can share one node — a server's accepted connections, a gifter's
;; exporter dial — while the C host sees one caller at a time; everything that
;; can block (socket writes, dial executors, listener fires) runs after the
;; lock releases. Reads happen outside the lock too: `pump-until` makes one
;; thread the connection's reader (the `async-connection` reader gate) and
;; parks everyone else on the node's progress event, so a settle fired by a
;; sibling connection's feed wakes a pump parked on its own quiet socket.

(require ffi/unsafe
         racket/tcp
         racket/async-channel
         racket/runtime-path
         "constants.rkt"
         "ffi-ocapn.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
         "value.rkt"
         "codec.rkt"
         "vat.rkt"
         "locator.rkt"
         "async.rkt"
         "host.rkt"
         "trampoline.rkt")

(provide (all-defined-out)
         (all-from-out "async.rkt")
         (all-from-out "host.rkt"))

;; A connection carries its pump state (`async`), its vat, the `node` it
;; belongs to, and its `conn-id` — the opaque PancakeHostConn handle the host
;; minted for it. The node (Goblins `mycapn` analogue, ADR-0009/ADR-0056/
;; ADR-0066) redeems three-party handoff gives transparently and routes
;; redeemed-capability sends to the exporter that hosts them, so the
;; application's `conn-send`/`conn-fetch`/`conn-tell` surface never sees a give.
;; `pending-writes`/`write-gate` carry encoded outbound frames from the locked
;; action drain to the socket: the drain pops `take_outbound` under the node
;; lock (a host verb) into the FIFO, and the write happens after the lock
;; releases, under the per-connection gate — so a slow partner's socket stalls
;; its own connection's writer, never every thread sharing the node. The FIFO
;; is the order authority: whichever thread holds the gate writes everything
;; queued so far, in queue order, so frames never reorder on the wire.
(struct connection (async vat node conn-id pending-writes write-gate))

;; While true, a settle/fetch callback fired by a far-vow *break* (a dead
;; transport, a released connection) rather than a partner resolution, so the
;; awaiting verb classifies it as the typed ERR-CLOSED instead of ERR-BROKEN.
(define current-breaking (make-parameter #f))

(define (conn-ptr c) (connection-conn-id c))
(define (conn-async c) (connection-async c))
(define (conn-vat c) (connection-vat c))
(define (conn-closed? c) (unbox (async-connection-closed? (connection-async c))))
(define (conn-released? c) (unbox (async-connection-released? (connection-async c))))

(define (guard-open who c)
  (when (conn-released? c)
    (raise-pancake who ERR-CLOSED "connection closed")))

;; Nonzero once the keyed handshake has completed and the session is open.
(define (conn-session-open? c)
  (and (not (conn-released? c))
       (= 1 (pancake_host_conn_session_open (conn-ptr c)))))

;; The typed cause of this connection's most recent local dispatch failure, or
;; #f — the host counterpart of the Zig `Peer.lastAbort`, read through the
;; shared `PancakeLastAbort` layout.
(define (conn-last-abort c)
  (define out (make-PancakeLastAbort 0 0 #f 0 #f 0 #f 0))
  (define rc (pancake_host_conn_last_abort (conn-ptr c) out))
  (cond
    [(= rc WOULD-BLOCK) #f]
    [else (check/host rc) (abort-info<-c out)]))

;; ── Distributed GC (ADR-0063), opt-in and off by default ─────────────────────
;; A connection opted in with `conn-with-gc!` carries a gc-state in this weak
;; table; absent means GC is off. The `connection` struct itself stays
;; immutable, so the state lives beside it keyed by identity. The table is weak
;; so a dropped connection's state is reclaimed with it.
(define gc-states (make-weak-hasheq))

;; The per-connection GC state: an async-channel onto which a fetched
;; capability's finalizer (run on Racket's finalizer thread) parks its token.
;; The connection's own verbs drain it on a pumping thread, where the host FFI
;; is safe to touch, and release one delta per parked token through
;; `pancake_host_gc_release` — never from the finalizer thread.
(struct gc-state (channel))

;; Opt this connection into distributed GC (ADR-0063), off by default. Once on,
;; a far capability returned by `conn-fetch` releases its import to the partner
;; when Racket's collector reclaims the last reference to it, so the partner can
;; release the matching export. Collection is best-effort on the collector's
;; schedule. Capabilities lifted elsewhere (a `conn-send` reply, a delivered
;; argument, a `conn-enliven` result the dedup cache owns) are outside this
;; seam. Returns the connection for chaining.
(define (conn-with-gc! c)
  (hash-set! gc-states c (gc-state (make-async-channel)))
  c)

;; Register a fetched capability for GC when GC is on. `ref` is the node-unique
;; token the application holds (ADR-0069); the host resolves it to its home
;; connection and real wire import when the release fires. The finalizer
;; captures only the integer token, never the `far-ref`, so it cannot resurrect
;; the handle whose death it waits on.
(define (track-import! c ref)
  (define gs (hash-ref gc-states c #f))
  (when (and gs (far-ref? ref) (>= (far-ref-id ref) REDEEMED-TOKEN-BASE))
    (define id (far-ref-id ref))
    (define ch (gc-state-channel gs))
    (register-finalizer ref (lambda (_) (async-channel-put ch id))))
  ref)

;; Drain the parked GC releases on the calling (pumping) thread: one release
;; delta per reclaimed token, then flush. Best-effort — a refused release
;; strands a partner export reclaimed at teardown, never a fault. Called at the
;; head of the connection's own verbs, so a release queued by a finalizer rides
;; out on the next thing the connection does.
(define (drain-gc! c)
  (define gs (hash-ref gc-states c #f))
  (when gs
    (define ch (gc-state-channel gs))
    (define drained
      (let loop ([acc '()])
        (define id (sync/timeout 0 ch))
        (if id (loop (cons id acc)) acc)))
    (unless (null? drained)
      (define m (connection-node c))
      (with-node-drain m
        (lambda ()
          (for ([id (in-list drained)])
            (with-handlers ([converts-to-broken? void])
              (check/host (pancake_host_gc_release (node-ptr m) id 1))))
          (drain-node-actions! m))))))

;; ── The action drain and the pump ─────────────────────────────────────────────

;; Pop every encoded outbound frame on `c` into its pending-writes FIFO, in
;; queue order. Caller holds the node lock (`take_outbound` is a host verb);
;; the socket write happens after the lock releases, through `write-pending!`.
(define (drain-outbound! c)
  (unless (conn-released? c)
    (let loop ()
      (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
      (define rc (pancake_host_conn_take_outbound (conn-ptr c) mf))
      (cond
        [(= rc WOULD-BLOCK) (void)]
        [else
         (check/host rc)
         (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
         (pancake_managed_frame_release mf)
         (async-channel-put (connection-pending-writes c) out)
         (loop)]))))

;; Write everything parked on `c`'s pending-writes FIFO to the transport,
;; flushing once, serialized by the connection's write gate. Runs outside the
;; node lock; a dead transport's write error is the caller's to tolerate.
(define (write-pending! c)
  (unless (conn-released? c)
    (define tr (async-connection-transport (connection-async c)))
    (call-with-semaphore
     (connection-write-gate c)
     (lambda ()
       (let loop ([wrote? #f])
         (define out (async-channel-try-get (connection-pending-writes c)))
         (cond
           [out ((async-transport-write-frame! tr) out) (loop #t)]
           [wrote? ((async-transport-flush! tr))]
           [else (void)]))))))

;; Write every connection a drain flushed, tolerating a dead transport per
;; connection so one broken partner never strands another's frames.
(define (write-touched! touched)
  (for ([c (in-list touched)])
    (with-handlers ([converts-to-broken? void]) (write-pending! c))))

;; What one locked drain hands back to run once the node lock releases: the
;; connections whose outbound was drained, and the deferred fires — settled
;; vows' listeners, dial executors, condemned-connection closes. Everything
;; here must run post-lock: a socket write can block, a dial is a connect
;; syscall plus a whole keyed handshake, and a listener is application code
;; that may pump. A fire still runs inside the reader window of the
;; connection whose feed produced it, so a listener may pump *other*
;; connections but must only enqueue on this one.
(struct drain-effects (touched fires))
(define no-drain-effects (drain-effects '() '()))

(define (run-drain-effects! fx)
  (write-touched! (drain-effects-touched fx))
  (for ([fire (in-list (drain-effects-fires fx))])
    (with-handlers ([converts-to-broken? void]) (fire))))

;; The one loop rule's drain: pop actions until dry, honoring each, and return
;; the `drain-effects` — parked writes and listener fires — the caller runs
;; with `run-drain-effects!` once the node lock is released. The node lock is
;; held. FLUSH order is action order, which is how the gifter's deposit leaves
;; on the exporter connection before the give leaves on the serving one (the
;; host queues them exporter-first); the per-connection FIFO preserves that
;; order across threads. SETTLE/FAIL route each vow's outcome to the
;; `conn-vow` awaiting that id — registered at mint under this same lock, so
;; the completion always finds its box.
(define (drain-node-actions! m)
  (let loop ([touched '()] [fires '()])
    (define a (node-next-action! m))
    (cond
      [(not a) (drain-effects (reverse touched) (reverse fires))]
      [else
       (case (car a)
         [(flush)
          (define c (node-connection-for-ptr m (cadr a)))
          (cond
            [c
             (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
             (loop (if (memq c touched) touched (cons c touched)) fires)]
            [else (loop touched fires)])]
         [(close)
          ;; The host condemned the connection mid-pump (local turn budget
          ;; exceeded): drain its queued resource_exhausted abort so the
          ;; post-lock write carries it, then close the transport and release
          ;; the shell — deferred to the fires, which run after the touched
          ;; writes, once the node lock is released.
          (define c (node-connection-for-ptr m (cadr a)))
          (cond
            [c
             (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
             (loop (if (memq c touched) touched (cons c touched))
                   (cons (lambda () (connection-close! c)) fires))]
            [else (loop touched fires)])]
         [(dial)
          ;; A dial is a connect syscall plus a whole keyed handshake:
          ;; post-lock, like every write and fire, or one slow exporter
          ;; parks every thread sharing the node.
          (loop touched (cons (lambda () (apply run-dial! m (cdr a))) fires))]
         [(need-gift-id) (node-provide-gift-id! m (cadr a)) (loop touched fires)]
         [(settle)
          (loop touched (append (reverse (settle-vow! m (cadr a) (cons 'ok (caddr a)))) fires))]
         [(fail)
          (define outcome (cons (if (current-breaking) 'closed 'broken) (caddr a)))
          (loop touched (append (reverse (settle-vow! m (cadr a) outcome)) fires))])])))

;; The one drain choreography every host-driving path shares: run `thunk`
;; under the node lock — it returns the locked drain's `drain-effects` (most
;; sites end in `drain-node-actions!`; some substitute `no-drain-effects` or a
;; merged record) plus any extra values — then run those effects (socket
;; writes, listener fires) after the lock releases, wake every parked pump,
;; and hand the extra values back to the caller.
(define (with-node-drain m thunk)
  (call-with-values
   (lambda () (call-with-node m thunk))
   (lambda (fx . rest)
     (run-drain-effects! fx)
     (node-bump-progress! m)
     (apply values rest))))

;; The breaking window the teardown paths share: unless `c` is already
;; released (its handle must see no further host verb), run `thunk` and drain
;; what it queued with completions classified as closure (`current-breaking`),
;; all inside one `with-node-drain`.
(define (with-breaking-drain c thunk)
  (define m (connection-node c))
  (with-node-drain m
    (lambda ()
      (cond
        [(conn-released? c) no-drain-effects]
        [else
         (parameterize ([current-breaking #t])
           (thunk)
           (drain-node-actions! m))]))))

;; Drain actions under the lock, write the flushed connections after it
;; releases, and wake every parked pump. A no-op inside a hosted turn: the
;; host refuses the driving verbs there, and everything the turn enqueued
;; flushes when the enclosing feed unwinds into this same drain.
(define (drain-node! m)
  (unless (inside-turn?)
    (with-node-drain m (lambda () (drain-node-actions! m)))))

;; Feed the connection's buffered inbound bytes into the host through the
;; core's stream delimiter (`pancake_host_conn_feed_bytes`): the session's
;; codec splits each complete frame off the front — both codecs, both frame
;; shapes, the frame cap enforced during the scan — and dispatches it (behavior
;; and settle callbacks fire inside), then the actions the dispatch queued
;; drain. Only the unconsumed tail stays in the inbox. Returns the consumed
;; byte count, zero when the inbox is empty or holds only a partial frame. On
;; a refused stream the peer has already projected a typed op:abort; write it
;; so the partner hears why, then raise the typed failure carrying the
;; connection's `abort-info`.
(define (feed-inbox! c)
  (define ac (connection-async c))
  (define bs (async-connection-inbox ac))
  (cond
    [(zero? (bytes-length bs)) 0]
    [else
     (guard-open 'conn-serve c)
     (define m (connection-node c))
     ;; Two values ride out of the locked drain: the consumed byte count and
     ;; the refusal captured under the lock (raised only after the effects ran
     ;; and the pumps woke, so the projected op:abort is already parked).
     (define-values (consumed refusal)
       (with-node-drain m
         (lambda ()
           (define buf (pin-immobile bs))
           (define-values (rc n)
             (pancake_host_conn_feed_bytes (conn-ptr c) buf (bytes-length bs)))
           (cond
             [(= rc OK)
              (async-consume! ac n)
              (values (drain-node-actions! m) n #f)]
             [else (values no-drain-effects 0 (capture-feed-refusal c rc))]))))
     (when refusal (raise-feed-refusal c refusal))
     consumed]))

;; Append freshly read bytes onto the inbox and feed it — the pump's
;; fill-then-feed step, and the scripted smoke's byte-injection seam.
(define (feed-bytes! c got)
  (async-fill! (connection-async c) got)
  (feed-inbox! c))

;; The feed refusal choreography, split around the node lock. Under the lock
;; (`capture-feed-refusal`): read the typed cause before another verb can
;; clobber the last-error slot, and park the projected op:abort on the
;; connection's pending-writes FIFO (`take_outbound` is a host verb). After
;; the lock releases (`raise-feed-refusal`): write the abort so the partner
;; hears why — a socket write must never run under the node lock, teardown
;; included — then raise the typed failure carrying the `abort-info`.
(define (capture-feed-refusal c rc)
  (define msg (host-last-error))
  (define abort (conn-last-abort c))
  (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
  (list rc msg abort))

(define (raise-feed-refusal c refusal)
  (with-handlers ([converts-to-broken? void]) (write-pending! c))
  (define rc (car refusal))
  (define msg (cadr refusal))
  (define abort (caddr refusal))
  (define base
    (if msg (format "pancake error ~a: ~a" rc msg) (format "pancake error ~a" rc)))
  (raise (exn:fail:pancake
          (if abort
              (format "~a [~a~a: ~a]" base (abort-info-domain abort)
                      (if (abort-info-kind abort) (format " ~a" (abort-info-kind abort)) "")
                      (abort-info-message abort))
              base)
          (current-continuation-marks) rc abort)))

;; The transport reported end of stream: break every far vow still parked here
;; (their resolutions can never arrive — with the partner's retained abort
;; diagnostic when one was received), classify those settles as closure, and
;; wake every parked pump.
(define (handle-conn-eof! c)
  (define ac (connection-async c))
  (unless (unbox (async-connection-closed? ac))
    (set-box! (async-connection-closed? ac) #t)
    ;; The breaking window: the FAIL completions the break queues classify as
    ;; closure.
    (with-breaking-drain c
      (lambda ()
        (define msg #"connection closed")
        (check/host (pancake_host_conn_break_far_vows
                     (conn-ptr c) (pin-immobile msg) (bytes-length msg)))))))

;; One reader step: feed whatever the inbox already buffers; when that made no
;; progress (empty, or a partial frame needing more bytes), wait on the
;; transport and the node's progress event together — 'woke means another
;; thread moved the host, so the caller re-checks its predicate.
(define (pump-read-once! c gen)
  (define ac (connection-async c))
  (when (zero? (feed-inbox! c))
    (define got
      ;; A port closed under us (another thread's `connection-close!`) is an
      ;; end of stream, not a fault.
      (with-handlers ([exn:fail? (lambda (_e) eof)])
        ((async-transport-fill-inbox! (async-connection-transport ac)) gen)))
    (cond
      [(eq? got 'woke) (void)]
      [(eof-object? got) (handle-conn-eof! c)]
      [else (feed-bytes! c got)])))

;; Drive the connection until `done` returns non-#f, returning that value.
;; Exactly one thread reads the transport at a time (the reader gate); every
;; other pump on this node parks on the progress event and re-checks. The
;; closed check runs after `done`, so a predicate satisfied by the closure
;; itself (a vow broken by the disconnect, `conn-serve`'s own exit) wins over
;; the typed ERR-CLOSED refusal.
(define (pump-until c done who #:closed-message [closed-message #f])
  (define m (connection-node c))
  (define ac (connection-async c))
  (let loop ()
    (drain-node! m)
    (define gen (node-progress-evt m))
    (define r (done))
    (cond
      [r r]
      [(unbox (async-connection-closed? ac))
       (raise-pancake who ERR-CLOSED "~a" (or closed-message "connection closed"))]
      [(box-cas! (async-connection-reader ac) #f (current-thread))
       (dynamic-wind
        void
        (lambda () (pump-read-once! c gen))
        (lambda ()
          (set-box! (async-connection-reader ac) #f)
          (node-bump-progress! m)))
       (loop)]
      [else (sync gen) (loop)])))

;; ── Far vows ──────────────────────────────────────────────────────────────────
;; The handle a far eventual-send returns: the host vow id, its home
;; connection, the settled state, and the Racket listeners waiting on it. The
;; vow is registered in the node's vow table the instant it is minted, under
;; the same node lock as the minting FFI call, and the action drain's
;; SETTLE/FAIL arms record the outcome here — so a late `on`/`conn-await`
;; still settles from the recorded state (the binding's spelling of the
;; resolution stash the other bindings keep), and no settle callback ever
;; crosses the C boundary.
(struct conn-vow (conn id [state #:mutable] [listeners #:mutable]) #:transparent)

;; Register a freshly minted vow so the drain can route its completion.
;; Caller holds the node lock, so no drain can pop the completion first.
(define (register-vow! m v)
  (hash-set! (node-vows m) (conn-vow-id v) v))

;; The drain's settle arm: record the outcome, drop the table row (a vow
;; settles once), and hand back the parked listeners as fire thunks — a
;; listener is arbitrary application code (the vat's `on`), so it must run
;; after the node lock releases, never under it, or a listener that pumps
;; could park the whole node. State mutation stays under the lock, so a
;; blocking `conn-await`'s state poll never races the fire. An unregistered
;; id yields nothing — an outcome nobody awaits.
(define (settle-vow! m id outcome)
  (define v (hash-ref (node-vows m) id #f))
  (cond
    [v
     (hash-remove! (node-vows m) id)
     (set-conn-vow-state! v outcome)
     (define ls (conn-vow-listeners v))
     (set-conn-vow-listeners! v '())
     (for/list ([l (in-list (reverse ls))])
       (lambda () (l (cdr outcome) (not (eq? (car outcome) 'ok)))))]
    [else '()]))

;; Register `(listener value broken?)` on a far vow: fire now from the recorded
;; state when it already settled, else park it for the drain's settle arm. The
;; vat's `on` reaches far vows through this (via the installed far half).
(define (conn-vow-listen! a-vow listener)
  (unless (conn-vow? a-vow) (error 'on "not a vow: ~a" a-vow))
  (define s (conn-vow-state a-vow))
  (cond
    [(eq? s 'pending)
     (set-conn-vow-listeners! a-vow (cons listener (conn-vow-listeners a-vow)))]
    [(eq? (car s) 'ok) (listener (cdr s) #f)]
    [else (listener (cdr s) #t)]))

;; The far half of `<-`/`<-np`/`conn-send`/`conn-send-promise`: marshal the
;; verb and args and enqueue through the host. A far target routes on its own
;; connection through the node (a redeemed or fetched token rides its exporter
;; transparently); a far vow target pipelines against the unresolved answer
;; (ADR-0007). An empty verb symbol is a methodless positional deliver
;; (verb length zero on the wire). Nothing is flushed here — the bytes leave on
;; the next drain, so a pipelined chain travels as one batch on the settling
;; send's pump. Legal inside a hosted turn (the host encodes at unwind).
(define (conn-far-send c target verb args answer?)
  (guard-open 'conn-send c)
  (define m (connection-node c))
  (define vb (string->bytes/utf-8 (symbol->string verb)))
  (define vbuf (pin-immobile vb))
  (define vlen (bytes-length vb))
  (call-with-node m
    (lambda ()
      (define keep (box '()))
      (define-values (aptr acnt) (args->c args keep))
      (cond
        [(conn-vow? target)
         (define-values (rc id)
           (pancake_host_vow_send (node-ptr m) (conn-vow-id target) vbuf vlen aptr acnt))
         (check/host rc)
         (define home (conn-vow-conn target))
         (define v (conn-vow home id 'pending '()))
         (register-vow! m v)
         (if answer? v (void))]
        [(or (far-ref? target) (near-ref? target))
         (cond
           [answer?
            (define-values (rc id)
              (pancake_host_conn_send (conn-ptr c) (ref->c target) vbuf vlen aptr acnt))
            (check/host rc)
            (define v (conn-vow c id 'pending '()))
            (register-vow! m v)
            v]
           [else
            (check/host (pancake_host_conn_tell (conn-ptr c) (ref->c target) vbuf vlen aptr acnt))
            (void)])]
        [else
         (raise-pancake 'conn-send ERR-INVALID-ARGUMENT "not a sendable reference: ~a" target)]))))

;; Break every far vow still parked on `c`, firing each listener with
;; `message` (or the partner's retained abort diagnostic when one arrived).
;; The vat-level `break-far-vows!` reaches here through the installed far half.
(define (conn-break-far-vows! c message)
  ;; The breaking window: the break's queued FAIL completions classify as
  ;; closure, not partner breaks.
  (with-breaking-drain c
    (lambda ()
      (define bs (string->bytes/utf-8 message))
      (check/host (pancake_host_conn_break_far_vows
                   (conn-ptr c) (pin-immobile bs) (bytes-length bs))))))

;; Pump until the far vow settles and classify: the fulfilled value, a typed
;; ERR-BROKEN carrying the partner's break, or a typed ERR-CLOSED when the
;; settle was the disconnect's own break.
(define (await-vow c v who label)
  (pump-until c
              (lambda () (and (not (eq? (conn-vow-state v) 'pending)) (conn-vow-state v)))
              who
              #:closed-message (format "connection closed before ~a settled" label))
  (define r (conn-vow-state v))
  (case (car r)
    [(ok) (cdr r)]
    [(closed) (raise-pancake who ERR-CLOSED "connection closed before ~a settled" label)]
    [else (raise-pancake who ERR-BROKEN "~a broke: ~a" label (cdr r))]))

;; ── Construction: build, establish, dial, listen, accept ─────────────────────

;; Wrap a freshly minted host connection in a `connection`: build the pump
;; state and the vat, install the vat's far half, and join the node's registry
;; so a FLUSH action and a routed send can find it. The single place a
;; `connection` is born, so every path shares the same wiring.
(define (build-connection m ptr transport time-travel?)
  (define ac (make-async-connection transport))
  (define v (make-vat #:time-travel? time-travel?))
  (define c (connection ac v m ptr (make-async-channel) (make-semaphore 1)))
  (set-box! (async-connection-conn ac) c)
  (vat-install-far!
   v
   (far-ops (lambda (ref method args answer?) (conn-far-send c ref method args answer?))
            (lambda (a-vow listener) (conn-vow-listen! a-vow listener))
            (lambda (message) (conn-break-far-vows! c message))))
  (node-register-connection! m ptr c)
  c)

;; Retire the connection from the node and free the C handle: parked far vows
;; break inside the release (classified as closure), stranded sibling withdraws
;; fail closed, and the queued teardown effects drain.
(define (abandon-connection! c)
  (define m (connection-node c))
  (define ac (connection-async c))
  (set-box! (async-connection-closed? ac) #t)
  ;; The abandoned connection's own parked frames die with it, but the drain
  ;; may flush a *different, healthy* connection (a sibling withdraw failing
  ;; closed), so the touched list is still written after the lock releases.
  ;; The breaking window: the release's queued FAIL completions classify as
  ;; closure.
  (with-breaking-drain c
    (lambda ()
      (set-box! (async-connection-released? ac) #t)
      (node-unregister-connection! m (conn-ptr c))
      (pancake_host_conn_release (conn-ptr c)))))

;; Drive a freshly opened connection's keyed handshake to an open session,
;; abandoning the connection on any failure so a rude partner costs one
;; accept, never the listener.
(define (finish-establish! c)
  (with-handlers ([(lambda (_) #t) (lambda (e) (abandon-connection! c) (raise e))])
    (drain-node! (connection-node c)) ; the signed op:start-session leaves now
    (pump-until c (lambda () (conn-session-open? c)) 'connect
                #:closed-message "connection closed during the OCapN handshake")
    c))

;; Mint the dialing half of a connection to the peer `locator-uri` names over
;; `transport` (an `async-transport` the caller opened) and drive the keyed
;; handshake open. The transport seam the companions build on: the iroh
;; companion calls this with its loop-driven transport.
(define (establish-dialed-connection m locator-uri transport #:time-travel? [time-travel? #f])
  (define ub (string->bytes/utf-8 locator-uri))
  (define c
    (call-with-node m
      (lambda ()
        (define-values (rc ptr)
          (pancake_host_conn_open_dialed (node-ptr m) (pin-immobile ub) (bytes-length ub)))
        (check/host rc)
        (build-connection m ptr transport time-travel?))))
  (finish-establish! c))

;; Mint the accepting half over a connection the caller's own listener
;; produced: the keyed op:start-session signs the listener's own
;; `transport-name`/`designator` — the address a partner can actually dial, and
;; the locator a give made on this node names as the exporter location.
(define (establish-accepted-connection m transport-name designator transport
                                       #:time-travel? [time-travel? #f])
  (define tb (string->bytes/utf-8 transport-name))
  (define db (string->bytes/utf-8 designator))
  (define c
    (call-with-node m
      (lambda ()
        (define-values (rc ptr)
          (pancake_host_conn_open_accepted (node-ptr m)
                                           (pin-immobile tb) (bytes-length tb)
                                           (pin-immobile db) (bytes-length db)))
        (check/host rc)
        (build-connection m ptr transport time-travel?))))
  (finish-establish! c))

;; The TCP dial mechanism behind `connect` and the redeem executor: open a
;; socket to host:port and drive the keyed handshake under node `m`'s retained
;; identity, so a fetched capability and any handoff it triggers share one
;; identity and connection table.
(define (dial-tcp host port m)
  (define-values (in out) (tcp-connect host port))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (with-handlers ([(lambda (_) #t) void])
                       (close-output-port out)
                       (close-input-port in))
                     (raise e))])
    (establish-dialed-connection m (tcp-locator host port) (port-transport in out))))

;; Dial host:port for `connect`. A shared `node` threads one node identity and
;; gift registry across several connections (the gifter side of a three-party
;; handoff); omit it for a standalone connection with a fresh identity.
(define (connect-tcp host port #:node [node #f] #:codec [codec #f])
  (dial-tcp host port (or node (make-fresh-node #:codec (or codec 'syrup)))))

;; ── The dial executor (a DIAL action's binding half) ─────────────────────────
;; The host asks for a dial with the exporter's full `ocapn://` locator URI and
;; its parsed pieces (transport, designator, direct-addresses hint) already on
;; the action, so the executor re-parses nothing; which netlayer answers — and
;; under which reachability posture — is the binding's decision, never the
;; ABI's. A `tcp` locator dials its host:port; an `iroh` locator with a
;; direct-address hint dials it relay-less (Direct), and a bare node id
;; resolves under the node's configured redeem posture (default Discovery;
;; `set-node-redeem-reachability!` lowers it), so one give shape covers an
;; offline direct dial and an internet dial-by-id alike. The iroh companion
;; loads lazily, only for an iroh give.
(define-runtime-path iroh-companion-path "../pancake-iroh.rkt")

(define (dial-exporter m uri transport designator addrs)
  (cond
    [(string=? transport "tcp")
     ;; The action's designator is the core grammar's parse; only its
     ;; host:port split is read here, refusing anything but a digits port.
     (define split (regexp-match #rx"^(.+):([0-9]+)$" designator))
     (define port (and split (string->number (caddr split))))
     (unless (and port (< port 65536))
       (raise-pancake 'conn-send ERR-INVALID-ARGUMENT
                      "tcp locator designator is not host:port: ~a" designator))
     (dial-tcp (cadr split) port m)]
    [(string=? transport "iroh")
     (define reach-direct (dynamic-require iroh-companion-path 'IROH-REACH-DIRECT))
     ((dynamic-require iroh-companion-path 'connect-iroh/node)
      designator addrs
      (if (= 0 (string-length addrs)) (node-redeem-reachability-value m) reach-direct) m)]
    [else
     (raise-pancake 'conn-send ERR-INVALID-ARGUMENT
                    "handoff redeem: unsupported exporter transport \"~a\" in ~a"
                    transport uri)]))

;; Execute one DIAL action, post-lock — the drain parks it among the fires,
;; because the dial is a connect syscall plus a whole keyed handshake and
;; would otherwise hold the node lock across both, parking every thread that
;; shares the node behind one slow exporter. The executor takes the lock only
;; inside the brief host verbs it contains, and each completion report opens
;; its own locked drain window, so the withdraw legs the report queues
;; (deposits, settles, flushes) drain as that report's own effects. A failed
;; dial breaks every waiting redeem with the reason. The exporter connection
;; is kept pumped by a background serve so the withdraw's resolution — and
;; any later routed traffic — is read.
(define (run-dial! m ticket locator-uri transport designator addrs)
  (with-handlers ([converts-to-broken?
                   (lambda (e)
                     (with-node-drain m
                       (lambda ()
                         (node-dial-failed! m ticket (exn->message e))
                         (drain-node-actions! m))))])
    (define c (dial-exporter m locator-uri transport designator addrs))
    (with-node-drain m
      (lambda ()
        (node-dialed! m ticket (conn-ptr c))
        (drain-node-actions! m)))
    (thread (lambda () (with-handlers ([converts-to-broken? void]) (conn-serve c))))
    (void)))

;; ── Hosting: listen and accept ────────────────────────────────────────────────
;; The host side of the same surface. `listen` binds host:port and returns a
;; server; `accept` blocks for the next partner, completes the keyed OCapN
;; handshake (the exchange is symmetric, both ends send their op:start-session
;; first, then read), and returns a ready connection exactly like `connect`.
;; Each accepted partner gets its own connection and vat. Pass port 0 for an
;; ephemeral port and read the bound one back with `server-port`. `accept`
;; takes `#:time-travel?`: pass #t to give the accepted connection's vat a
;; retained, revisable behavior history (every actor it hosts), off by default.
;; The server carries one `node` (read it with `server-node`): every accepted
;; connection shares its identity and gift registry, so a node-giftable
;; published on it with `node-publish-giftable` appears on each accepted
;; partner.
(struct server (listener node))

(define (listen host [port 0] #:codec [codec 'syrup])
  (define l (tcp-listen port 64 #t host))
  (define m (make-fresh-node #:codec codec))
  ;; This node also dials (the gifter side of a handoff), and its dials sign
  ;; the listener's own address so a partner's crossed-hellos table can
  ;; recognize it.
  (define-values (_h bound-port _rh _rp) (tcp-addresses l #t))
  (node-set-self-designator! m (format "~a:~a" host bound-port))
  (server l m))

(define (server-port s)
  (define-values (_host port _rh _rp) (tcp-addresses (server-listener s) #t))
  port)

(define (accept s #:time-travel? [time-travel? #f])
  (define-values (in out) (tcp-accept (server-listener s)))
  (define m (server-node s))
  (define-values (local-host local-port _rh _rp) (tcp-addresses in #t))
  (establish-accepted-connection m "tcp" (format "~a:~a" local-host local-port)
                                 (port-transport in out)
                                 #:time-travel? time-travel?))

;; Stop accepting new partners. Connections already accepted are unaffected.
(define (server-close! s) (tcp-close (server-listener s)))

;; Dial a partner from its `ocapn://` locator — the one dialer, dispatching on the
;; locator's transport: `iroh` dials the endpoint id with its `direct-addresses`
;; hints, `tcp` dials the `host:port` designator. There is no other dial: a
;; literal address is a `tcp` locator, built with `tcp-locator`. Parse once
;; through the core grammar, which picks the netlayer. `reachability` (an
;; IROH-REACH-* posture) governs the iroh branch and is required only when the
;; locator's transport is `iroh`; a `tcp` locator ignores it, so a plain TCP dial
;; needs nothing but the locator. An iroh locator with no posture fails closed
;; rather than guessing one.
;; `#:node` shares one node identity and gift registry across several
;; connections — the gifter side of a three-party handoff, where the same node
;; both serves recipients (via `listen`/`accept`) and dials the exporter it
;; re-gifts from. Omit it for a standalone connection with a fresh identity. Only
;; the `tcp` branch threads it today; supplying `#:node` with a non-tcp (iroh)
;; locator fails closed rather than silently dropping the shared identity and
;; dialing on a fresh node — a mis-encoded handoff with no error at the call that
;; caused it. Matches the Python binding's guard.
(define (connect uri [reachability #f] #:node [node #f] #:codec [codec #f])
  (define loc (parse-locator uri))
  (define transport (locator-transport loc))
  ;; Fail closed on a shared node the transport cannot honor. Dropping it silently
  ;; would dial on a different node than `node`, so a capability fetched here and
  ;; re-gifted is not recognized against the shared gift registry.
  (when (and node (not (string=? transport "tcp")))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "a shared node is supported only for tcp locators today"))
  ;; The codec is the node's: a fresh node is minted with `#:codec`, and a
  ;; shared node already carries one, so a conflicting explicit codec fails
  ;; closed instead of silently speaking a grammar the node does not.
  (when (and node codec (not (eq? codec (node-codec node))))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "#:codec ~a conflicts with the shared node's ~a" codec (node-codec node)))
  (when (and codec (not (string=? transport "tcp")))
    (raise-pancake 'connect ERR-INVALID-ARGUMENT
                   "a codec option is supported only for tcp locators today"))
  (cond
    [(string=? transport "iroh")
     (unless reachability
       (error 'connect "an iroh locator requires a reachability posture: ~a" uri))
     ;; Load the iroh companion lazily — only an iroh locator pulls in
     ;; libpancake_net_transport_iroh and its binding; a TCP-only program never
     ;; touches either.
     ((dynamic-require iroh-companion-path 'connect-iroh)
      (locator-designator loc) (hash-ref (locator-hints loc) "direct-addresses" "") reachability)]
    [(string=? transport "tcp")
     ;; The host:port split (and its validation) is the core grammar's, read
     ;; off the parsed locator — not a re-derived string scan.
     (unless (locator-host loc)
       (error 'connect "tcp locator designator is not host:port: ~a" (locator-designator loc)))
     (connect-tcp (locator-host loc) (locator-port loc) #:node node #:codec codec)]
    [else (error 'connect "unsupported transport \"~a\"" transport)]))

;; Record the dialable exporter location this connection's gifter origination
;; signs into a give, in place of the exporter's own signed session record
;; (ADR-0009). `raw-locator` is the verbatim bytes from `encode-peer-locator`
;; (read off the registered exporter URI). A rendezvous that learned a member's
;; iroh URI sets it so a give can name an exporter reachable only by a dial hint
;; under the relay-less `Direct` posture. Unset, origination uses the partner's
;; signed location.
(define (conn-set-exporter-locator! c raw-locator)
  (call-with-node (connection-node c)
    (lambda ()
      (check/host (pancake_host_conn_set_exporter_location
                   (conn-ptr c) (pin-immobile raw-locator) (bytes-length raw-locator))))))

;; Flush whatever is already queued on the host's outbound to the wire. A `<-`
;; far-send only enqueues; the bytes leave when something drains. The blocking
;; verbs drain themselves, but work another green thread queues onto this node
;; — a server pushing a broadcast to a subscriber whose own thread is parked
;; reading — would sit unsent until that thread woke. Call `conn-flush!` right
;; after such a cross-thread send to put the bytes on the wire now.
(define (conn-flush! c)
  (define m (connection-node c))
  (unless (inside-turn?)
    (with-node-drain m
      (lambda ()
        ;; This connection is flushed whether or not an action named it, so it
        ;; is merged into the drained effects' touched list.
        (define drained (drain-node-actions! m))
        (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
        (define touched (drain-effects-touched drained))
        (drain-effects (if (memq c touched) touched (cons c touched))
                       (drain-effects-fires drained))))))

;; Named `connection-close!` with the full prefix, keeping the
;; application-surface close distinct from the netlayer's `endpoint-release!`.
;; Close the connection: stop the transport first, then retire the node's
;; entry and free the host handle, so no foreign call touches a freed
;; connection.
(define (connection-close! c)
  (define ac (connection-async c))
  ((async-transport-close! (async-connection-transport ac)))
  (abandon-connection! c))

;; ── Spawning, publishing, and the proxy verbs ─────────────────────────────────

;; Host `actor` on connection `c`: build the trampoline that runs the actor's
;; current cell on each wire deliver, bind it at a fresh export position —
;; through the turn-time spawn when called from inside a hosted turn (a served
;; factory minting the capability it replies with), through the top-level
;; publish/spawn otherwise — and record the export in the vat so a near
;; reference to it resolves in process. Returns the near capability.
(define (register-hosted-actor! c actor #:name [name #f])
  (define v (conn-vat c))
  (define m (connection-node c))
  (define tramp (make-actor-trampoline c v (actor-ref-id actor)))
  (node-retain! m tramp)
  (define turn (and (not name) (current-turn-for c)))
  (define pos
    (cond
      [turn (turn-spawn-position! turn tramp)]
      [else
       (call-with-node m
         (lambda ()
           (cond
             [name
              (define nb (string->bytes/utf-8 name))
              (define-values (rc p)
                (pancake_host_conn_publish (conn-ptr c) (pin-immobile nb) (bytes-length nb)
                                           tramp #f #f))
              (check/host rc)
              p]
             [else
              (define-values (rc p) (pancake_host_conn_spawn (conn-ptr c) tramp #f #f))
              (check/host rc)
              p])))]))
  (bind-export! v actor pos)
  (near pos))

;; Spawn a local actor at a fresh export position and return a near capability
;; to hand a partner. `(conn-spawn c ^name arg …)` constructs like `spawn`. The
;; position comes from the session's one export allocator, so it can never
;; alias a bootstrap or resolver export. Callable from inside a served turn (a
;; factory's `create` minting the task it replies with).
(define (conn-spawn c constructor . args)
  (define actor (with-vat (conn-vat c) (apply spawn constructor args)))
  (register-hosted-actor! c actor))

;; Publish an actor fetchable by name (a swiss-number). Returns the near
;; capability.
(define (conn-publish c name constructor . args)
  (define actor (with-vat (conn-vat c) (apply spawn constructor args)))
  (register-hosted-actor! c actor #:name name))

;; Wrap `target` (a near capability this connection spawned or a far one it
;; fetched) in a revocable caretaker (ADR-0064). Returns the proxy near capability
;; to hand a partner; every call through it forwards to `target` until
;; `conn-revoke!`, after which each breaks with "Revoked". `target` may be a
;; capability imported over the wire — the proxy forwards transparently — so this
;; hands out a revocable view of authority you do not own locally.
(define (conn-caretaker c target)
  (define v (conn-vat c))
  (define resolved (vat-resolve-target v target))
  (define live (box #t))
  ;; An ordinary spawned actor whose behavior tail-forwards to the target — so the
  ;; proxy answers a local call exactly as a partner's delivery does.
  (define actor
    (with-vat v
      (spawn (lambda (bcom)
               (lambda (method . args)
                 (if (unbox live)
                     (forward resolved method args)
                     (error "Revoked")))))))
  (define proxy (register-hosted-actor! c actor))
  (hash-set! (vat-revocables v) (near-ref-id proxy) live)
  proxy)

;; Wrap `target` in an attenuator (ADR-0064): a proxy that forwards only the
;; calls whose verb is in `verbs` (strings or symbols) and breaks every other
;; with "Attenuated". Returns the proxy near capability to hand a partner. The
;; proxy is a plain spawned actor.
(define (conn-attenuate c target verbs)
  (define v (conn-vat c))
  (define resolved (vat-resolve-target v target))
  (define allow (map (lambda (verb) (if (symbol? verb) (symbol->string verb) verb)) verbs))
  (define actor
    (with-vat v
      (spawn (lambda (bcom)
               (lambda (method . args)
                 (if (member (symbol->string method) allow)
                     (forward resolved method args)
                     (error "Attenuated")))))))
  (register-hosted-actor! c actor))

;; Revoke a caretaker `proxy` (the near capability `conn-caretaker` returned):
;; every later call through it breaks with "Revoked". Idempotent. Clears the
;; shared `live` flag the proxy actor reads, then drops the lookup entry so the
;; revocables table does not grow one row per caretaker for the vat's whole life
;; (the proxy holds the flag by closure, so it stays revoked without the entry).
(define (conn-revoke! c proxy)
  (unless (near-ref? proxy)
    (raise-pancake 'conn-revoke! ERR-INVALID-ARGUMENT
                   "revoke target is not a caretaker proxy: ~a" proxy))
  (define revocables (vat-revocables (conn-vat c)))
  (define live (hash-ref revocables (near-ref-id proxy) #f))
  (when live
    (set-box! live #f)
    (hash-remove! revocables (near-ref-id proxy))))

;; ── The application verbs ─────────────────────────────────────────────────────

;; Observe a local vow to settlement and classify: register the listener, run
;; the turn in `drive`, and — when a proxy forwarding to a far target deferred
;; the settle onto a wire reply — pump until it lands. Returns the fulfilled
;; value; a broken vow raises the typed ERR-BROKEN. `label` names the awaited
;; thing in every diagnostic. The one awaiting loop under `conn-send`'s local
;; arm and `conn-await`'s.
(define (await-local-vow c vow who label)
  (define v (conn-vat c))
  (define result (box 'pending))
  (with-vat v
    (on vow
        (lambda (val) (set-box! result (cons 'ok val)))
        #:catch (lambda (m) (set-box! result (cons 'broken m)))))
  (drive v)
  (unless (pair? (unbox result))
    (pump-until c (lambda () (pair? (unbox result))) who
                #:closed-message (format "connection closed before ~a settled" label)))
  (define r (unbox result))
  (if (eq? (car r) 'broken)
      (raise-pancake who ERR-BROKEN "~a broke: ~a" label (cdr r))
      (cdr r)))

;; The awaiting loop for a send whose target resolved to a local actor: the
;; turn runs in `drive`; a proxy forwarding to a far target defers the settle
;; onto the reply, which the pump reads off the wire.
(define (conn-send-local c resolved verb args)
  (define vow (with-vat (conn-vat c) (apply <- resolved verb args)))
  (await-local-vow c vow 'conn-send verb))

;; Eventual-send `verb` to `target` and drive the connection until the reply
;; settles, returning the fulfilled value, the request/reply half whose
;; fire-and-forget sibling is `conn-tell`. A `near-ref` this connection spawned
;; resolves in process; a partner's ref goes out on the wire, and a redeemed
;; handoff token routes to the exporter connection that hosts it. A broken
;; reply raises a typed `exn:fail:pancake` carrying PANCAKE_ERR_BROKEN, exactly
;; as the Python and Rust `send`s fail. Single-threaded: it pumps events
;; itself, matching the rest of the Racket binding.
(define (conn-send c target verb . args)
  (guard-open 'conn-send c)
  (drain-gc! c) ; flush any imports reclaimed since the last connection op
  (define resolved (vat-resolve-target (conn-vat c) target))
  (cond
    [(actor-ref? resolved) (conn-send-local c resolved verb args)]
    [else (await-vow c (conn-far-send c resolved verb args #t) 'conn-send verb)]))

;; Eventual-send `verb` to `target` and return its vow WITHOUT driving the
;; connection to a reply — the non-blocking half of `conn-send` and the seam
;; for promise pipelining (ADR-0007). The returned vow is itself a valid
;; `target` for a later `conn-send`/`conn-send-promise`/`conn-tell`, so a
;; dependent call rides a `desc:answer` deliver the partner queues until the
;; answer settles; a `create -> use` chain then costs one round trip. The
;; deliver is queued now and its bytes leave the wire when the chain is settled
;; by passing its tail to `conn-send` (which pumps to the value) — a chain
;; never settled is fire-and-forget, for which `conn-tell` is the right call.
;; A `near-ref` this connection spawned resolves in process.
(define (conn-send-promise c target verb . args)
  (guard-open 'conn-send-promise c)
  (define v (conn-vat c))
  (define resolved (vat-resolve-target v target))
  (cond
    [(actor-ref? resolved)
     (define vow (with-vat v (apply <- resolved verb args)))
     ;; A local target runs its turn now; a far/pipelined target leaves on the
     ;; settling `conn-send`'s pump, so the whole chain travels as one batch.
     (drive v)
     vow]
    [else (conn-far-send c resolved verb args #t)]))

;; ── Pipelined projections (ADR-0050) ─────────────────────────────────────────
;; Project an element or unwrapped tag out of a far vow WITHOUT waiting
;; for it to settle, returning a new vow for the projected value. The
;; projection rides the wire as `op:index` / `op:untag` against the
;; receiver's answer (ADR-0052), so it pipelines exactly like a dependent call:
;; `(conn-untag c vow "row")` then `(conn-index c that 0)` reaches the first
;; element of an unwrapped tagged record in one batch, before the source resolves.
;; The returned vow is itself a projection or `conn-send` target, and settles via
;; `conn-await`. Bytes leave on the next pump (a `conn-await`/`conn-send` drain),
;; matching `conn-send-promise`.
(define (conn-index c a-vow i)
  (project-vow c a-vow (lambda (m id) (pancake_host_vow_index (node-ptr m) id i))))

(define (conn-untag c a-vow tag)
  (define tb (string->bytes/utf-8 tag))
  (project-vow c a-vow
               (lambda (m id)
                 (pancake_host_vow_untag (node-ptr m) id (pin-immobile tb) (bytes-length tb)))))

(define (project-vow c a-vow mint)
  (unless (conn-vow? a-vow)
    (raise-pancake 'conn-project ERR-INVALID-ARGUMENT
                   "projection target is not a far vow: ~a" a-vow))
  (define m (connection-node c))
  (call-with-node m
    (lambda ()
      (define-values (rc id) (mint m (conn-vow-id a-vow)))
      (check/host rc)
      (define home (conn-vow-conn a-vow))
      (define v (conn-vow home id 'pending '()))
      (register-vow! m v)
      v)))

;; Drive the connection until `a-vow` settles, returning its fulfilled value,
;; the awaiting half of `conn-send-promise` / `conn-index` / `conn-untag`. A
;; broken vow raises a typed `exn:fail:pancake` (PANCAKE_ERR_BROKEN), as
;; `conn-send` does. A local vow settles in `drive`; a far vow on a wire reply
;; — or immediately, when the resolution already arrived while a sibling
;; projection pumped the loop. Single-threaded: it pumps events itself, like
;; the rest of the binding.
(define (conn-await c a-vow)
  (cond
    [(conn-vow? a-vow) (await-vow c a-vow 'conn-await "the vow")]
    [(local-vow? a-vow) (await-local-vow c a-vow 'conn-await "the vow")]
    [else
     (raise-pancake 'conn-await ERR-INVALID-ARGUMENT "not a vow: ~a" a-vow)]))

;; Fetch a partner's published capability by name, returning the far
;; reference. The canonical fetch lives in the library: one call registers the
;; bootstrap import, allocates the answer, and queues the deliver; the host
;; enrolls the fulfilled capability under a node-unique token (ADR-0069)
;; before the completion fires, so two capabilities fetched at the same wire
;; position on different connections never collide, and a return re-gifts the
;; right home. A partner break raises a typed pancake failure
;; (PANCAKE_ERR_BROKEN); a fetch that fulfills with anything but a capability
;; raises a typed unsupported-value failure, the same code the Python binding
;; uses for the same shape.
;; The one blocking fetch shape `conn-fetch` and `conn-enliven` share: `mint!`
;; runs the registering FFI verb (the one thing that differs) and returns the
;; minted vow id, the vow joins the node's table before the lock drops, and
;; the pump drains its SETTLE/FAIL completion off the action queue. Classify:
;; only a live near/far reference fulfills (anything else is rejected like the
;; other bindings and the Zig reference do, the typed unsupported-value
;; refusal), a partner break raises the typed ERR-BROKEN, and the disconnect's
;; own break the typed ERR-CLOSED. `what` is the verb word and `label` the
;; awaited name in every diagnostic.
(define (blocking-fetch c who what label mint!)
  (define m (connection-node c))
  (define v
    (call-with-node m
      (lambda ()
        (define-values (rc id) (mint!))
        (check/host rc)
        (define fresh (conn-vow c id 'pending '()))
        (register-vow! m fresh)
        fresh)))
  (pump-until c
              (lambda () (and (not (eq? (conn-vow-state v) 'pending)) (conn-vow-state v)))
              who
              #:closed-message (format "connection closed before \"~a\" settled" label))
  (define r (conn-vow-state v))
  (case (car r)
    [(ok)
     (define val (cdr r))
     (unless (or (near-ref? val) (far-ref? val))
       (raise-pancake who ERR-UNSUPPORTED-VALUE
                      "~a \"~a\" did not resolve to a capability: ~a" what label val))
     val]
    [(closed)
     (raise-pancake who ERR-CLOSED "connection closed before \"~a\" settled" label)]
    [else
     (raise-pancake who ERR-BROKEN "~a \"~a\" broke: ~a" what label (cdr r))]))

(define (conn-fetch c name)
  (guard-open 'conn-fetch c)
  (drain-gc! c) ; flush any imports reclaimed since the last connection op
  (define nb (string->bytes/utf-8 name))
  (track-import!
   c
   (blocking-fetch c 'conn-fetch "fetch" name
                   (lambda ()
                     (pancake_host_conn_fetch (conn-ptr c) (pin-immobile nb)
                                              (bytes-length nb))))))

;; Enliven a sturdyref against this connection (ADR-0012): bring the durable
;; `(peer, swissnum)` to life as a live capability. Parses `sturdyref` for its
;; swissnum, then fetches it through the host's dedup cache — a repeat enliven
;; of the same swissnum on this session short-circuits with no wire traffic
;; (its SETTLE completion is queued before the minting call returns). The
;; connection must already be open to the sturdyref's peer; the sans-io core
;; tracks no remote locator and never dials. A partner break raises a typed
;; PANCAKE_ERR_BROKEN; a fulfill that is not a capability raises the typed
;; unsupported-value failure, matching `conn-fetch` and the other bindings.
(define (conn-enliven c sturdyref)
  (guard-open 'conn-enliven c)
  (define swissnum
    (string->bytes/utf-8 (locator-swissnum (parse-locator sturdyref #:sturdyref? #t))))
  (blocking-fetch c 'conn-enliven "enliven" sturdyref
                  (lambda ()
                    (pancake_host_conn_enliven (conn-ptr c) (pin-immobile swissnum)
                                               (bytes-length swissnum)))))

;; Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and no
;; reply comes back, so a notification or broadcast costs one deliver. A
;; self-spawned target runs its turn in-process (like `conn-send`); a far one
;; flushes the deliver to the wire.
(define (conn-tell c target verb . args)
  (guard-open 'conn-tell c)
  (define v (conn-vat c))
  (define resolved (vat-resolve-target v target))
  (cond
    [(actor-ref? resolved)
     (with-vat v (apply <-np resolved verb args))
     (drive v)]
    [else
     (conn-far-send c resolved verb args #f)
     (drain-node! (connection-node c))]))

;; Drive inbound frames into the host until the connection closes: hosted
;; actors run, far vows settle, and the node's actions execute, all inside the
;; pump. When the wire is gone the pump has already broken every far vow still
;; awaiting a reply (with the partner's retained abort diagnostic when one
;; arrived), the same disconnect guarantee the Deno and Python connections give.
(define (conn-serve c)
  (drain-gc! c)
  (pump-until c
              (lambda () (and (conn-closed? c) 'closed))
              'conn-serve)
  (void))
