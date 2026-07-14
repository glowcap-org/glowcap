#lang racket/base
;; Internal: distributed GC (ADR-0063), opt-in and off by default. Owns
;; `session-with-gc!` / `track-import!` / `drain-gc!`, the weak per-connection
;; state table, the finalizer park, and `pancake_host_gc_release`. Session
;; keeps CapTP verbs that call these. Binding spine Pass 3b.

(require ffi/unsafe
         racket/async-channel
         racket/lazy-require
         "constants.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
         "value.rkt"
         "vat.rkt"
         "host.rkt"
         "action.rkt")

;; `session-host` / drain helpers live in session.rkt — lazy-require breaks
;; the session ↔ gc cycle (session eagerly requires this module).
(lazy-require
 ["session.rkt"
  (session-host
   with-host-drain)])

(provide session-with-gc!
         track-import!
         drain-gc!)

;; A connection opted in with `session-with-gc!` carries a gc-state in this weak
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

;; Opt this session into distributed GC (ADR-0063), off by default. Once on,
;; a far capability returned by `session-fetch` releases its import to the partner
;; when Racket's collector reclaims the last reference to it, so the partner can
;; release the matching export. Collection is best-effort on the collector's
;; schedule. Capabilities lifted elsewhere (a `session-send` reply, a delivered
;; argument, a `session-enliven` result the dedup cache owns) are outside this
;; seam. Returns the session for chaining.
(define (session-with-gc! c)
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
      (define m (session-host c))
      (with-host-drain m
        (lambda ()
          (for ([id (in-list drained)])
            (with-handlers ([converts-to-broken? void])
              (check/host (pancake_host_gc_release (host-ptr m) id 1))))
          (drain-host-actions! m))))))
