#lang racket/base
;; Internal: the CapTP `host` — binding wrapper for `PancakeHost` /
;; `driver_core.Host` (ADR-0072 / ADR-0079). The host owns an `engine.Node`
;; (the sans-io handoff router). Goblins `mycapn` is two roles, not one type:
;; the product maps to this Host; the router tables map to `engine.Node`. What lives
;; here is only what the embedder contract leaves to the binding: the host
;; handle and its reentrant lock (one green-thread scheduler drives one host,
;; and the lock is what makes "one at a time" true across this binding's
;; threads), the session-pointer → session registry the action drain routes by,
;; the giftable trampolines' strong retention, gift-id entropy, and the iroh
;; redeem-reachability posture the dial executor reads. Action decode +
;; execute (`drain-host-actions!` via `pancake_host_pump_drain`) live in
;; `private/action.rkt`; the dial executor lives in `private/dial.rkt`;
;; the session byte path lives in `private/pump.rkt`.

(require ffi/unsafe
         racket/random
         "constants.rkt"
         "ffi-shared.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "locator.rkt"
         "trace.rkt"
         "codec.rkt"
         "trampoline.rkt")

(provide (all-defined-out))

;; Every session's maximum admissible frame; mirrors PANCAKE_DEFAULT_FRAME_CAP.
(define HOST-FRAME-CAP DEFAULT-FRAME-CAP)

;; The host. `ptr` is the PancakeHost handle; `lock`/`lock-owner` form the
;; reentrant host lock every `pancake_host_*` verb and action drain runs under;
;; `sessions` maps a session pointer's address to its live `session` (the FLUSH
;; action's routing table, and what keeps redeem-dialed exporter sessions
;; alive); `progress` boxes the generation semaphore pumps wait on — bumped
;; after every locked host operation, so a thread parked on one session
;; notices a settle another session's feed fired; `keep` strongly retains
;; every behavior closure registered with the host (a C trampoline stays alive
;; only while its Racket closure does); `vows` maps a host vow id to the
;; `session-vow` awaiting it, filled at mint under the host lock and settled by
;; the drain's SETTLE/FAIL arms (`private/promise.rkt`), so no callback
;; ever crosses the C boundary for a settlement; `redeem-reachability` is the
;; iroh posture a hint-less handoff give is redeemed under (starting at the
;; generated `IROH-REACH-REDEEM-DEFAULT`, Discovery;
;; `set-host-redeem-reachability!` lowers it for a relay-policy deployment);
;; `released?` guards the handle against use after release; `driver-loop`
;; boxes the native loop this host is adopted over (ADR-0112), or #f for a
;; byte-fed host — when set, the action drain, session release, and host
;; release all route through the loop via the hooks below.
(struct host ([ptr #:mutable] seed lock lock-owner sessions progress keep vows redeem-reachability rendezvous-url released? codec captp-version features driver-loop))

;; The native loop this host is adopted over, or #f. The one branch point
;; every loop-aware seam reads.
(define (host-loop-of m) (unbox (host-driver-loop m)))

;; ── The loop hooks (ADR-0112) ────────────────────────────────────────────────
;; `loop.rkt` fills these at module load — a loop-adopted host exists only
;; after that module ran, so a set hook is guaranteed wherever `host-loop-of`
;; answers a loop. Hook boxes rather than requires, because the release path
;; is reachable from the FFI finalizer thread, where a lazy-require stub
;; cannot resolve a module.
;;
;; The action drain's loop arm: one bracketed zero-timeout step plus the
;; event dispatch, in place of `pancake_host_pump_drain`, which never runs
;; beside a loop.
(define loop-drain-hook (box #f))
;; Stop stepping and join the park thread, run by `host-release!` OUTSIDE
;; the host lock (the park thread takes that lock to step).
(define loop-prestop-hook (box #f))
;; Native teardown in place of `pancake_host_release`: the loop releases
;; itself and the wrapped host together.
(define loop-native-release-hook (box #f))
;; A loop-owned session's release, through `pancake_driver_session_release`.
(define loop-session-release-hook (box #f))
;; Lazily wrap a session the loop minted internally (a redeem-dialed
;; exporter leg) as a public `session`.
(define loop-wrap-session-hook (box #f))

;; Release one native session handle through its owner: the loop for a
;; loop-adopted host, `pancake_host_session_release` for a byte-fed one.
(define (native-session-release! m ptr)
  (define lp (host-loop-of m))
  (if lp
      ((unbox loop-session-release-hook) lp ptr)
      (pancake_host_session_release ptr)))

;; `#:codec`, `#:captp-version`, and `#:features` are this host's signed
;; profile offer. Each session settles version and codec with its partner,
;; falling back to v1.0/Syrup when needed, and runs only the intersection of the
;; two offered feature sets. Omitted `#:features` means the full feature set.
;; The host remembers the symbols so
;; `connect` can refuse explicit profile options that conflict with a shared
;; host's.
(define (make-host seed #:codec [codec 'syrup] #:captp-version [captp-version 'v1_0]
                   #:features [features 'full]
                   #:local-turn-budget [local-turn-budget 0])
  (unless (and (bytes? seed) (= (bytes-length seed) 32))
    (raise-pancake 'make-host ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  ;; Keep an owned copy so caller mutation cannot split the native identity from
  ;; the seed used to derive the host's designator.
  (define durable-seed (bytes->immutable-bytes (bytes-copy seed)))
  ;; The durable identity followed by a session-key root drawn here, at this
  ;; binding's entropy boundary, because the library draws none (ADR-0097).
  ;; The root is fresh per process, so every CapTP session signs with its own
  ;; key and a restart cannot recreate a prior session's handoff names; the
  ;; durable half stays exactly `seed`, since a keyed locator's designator
  ;; derives from it.
  (define seed+root (bytes-append durable-seed (crypto-random-bytes 32)))
  (define sbuf (pin-immobile seed+root)) ; pin: the GC may move it mid-call
  (define-values (rc ptr)
    (pancake_host_new sbuf 64 HOST-FRAME-CAP 1 (codec-id codec)
                     (captp-version-id captp-version) (feature-mask features)
                     local-turn-budget))
  (check/host rc)
  (define m (host ptr durable-seed (make-semaphore 1) (box #f) (make-hash) (box (make-semaphore 0))
                  (make-hasheq) (make-hash) (box IROH-REACH-REDEEM-DEFAULT) (box #f) (box #f) codec captp-version features (box #f)))
  ;; The host's own key designator, which is what a partner names it by: the
  ;; live trace reports it as this host's endpoint so one peer stays one node
  ;; in a feed several producers share.
  (trace-attach-host! m host-install-trace! (designator-from-seed durable-seed))
  (register-finalizer m (lambda (q) (host-release! q #:close-sessions? #f)))
  m)

;; A host with a fresh random identity seed — entropy drawn at the binding
;; boundary, never inside the sans-io host.
(define (make-fresh-host #:codec [codec 'syrup] #:captp-version [captp-version 'v1_0]
                         #:features [features 'full]
                         #:local-turn-budget [local-turn-budget 0])
  (make-host (crypto-random-bytes 32) #:codec codec #:captp-version captp-version
             #:features features
             #:local-turn-budget local-turn-budget))

;; How `host-release!` closes the sessions it still holds. `session.rkt` fills
;; this in when it loads: it requires this module for CapTP verbs, so the
;; import only runs one way and this module cannot name `session-close!`.
(define close-session-hook (box #f))

;; `promise.rkt` installs the binding-level vow teardown without introducing a
;; host -> promise module cycle. It returns listener fire thunks, which release
;; runs only after dropping the host lock.
(define fail-host-vows-hook (box #f))

;; Hosts whose explicit release was requested from inside a native callback.
;; Pending is still live and must not suppress the finalizer.
(define host-release-pending (make-hasheq))

;; A Host release closes sessions, and a privately-owned session asks its Host
;; to release as part of that close. Keep that recursive cleanup from entering
;; native release a second time.
(define host-release-active (make-hasheq))

;; Release the host and everything it owns: close every session it still
;; holds — the ones an application opened and the ones the host dialed to
;; redeem handoffs alike — then free the handle. Closing a session closes that
;; one connection; this is what closes the rest.
;;
;; `close-sessions?` is #f on the finalizer path. A finalizer runs on the
;; collector's own thread, where touching a port is not safe, and a host being
;; collected has no reachable sessions left for anyone to observe.
(define (host-release! m #:close-sessions? [close-sessions? #t])
  (cond
    [(unbox (host-released? m)) (void)]
    [(hash-ref host-release-active m #f) (void)]
    [else
     (define release-now?
       (call-with-host/allow-released
        m
        (lambda ()
          (if (inside-turn?)
              (begin
                (unless (hash-ref host-release-pending m #f)
                  (hash-set! host-release-pending m #t)
                  (host-park-release!
                   m
                   (lambda ()
                     (hash-remove! host-release-pending m)
                     (host-release! m #:close-sessions? close-sessions?))))
                #f)
              (begin
                (hash-set! host-release-active m #t)
                #t)))))
     (when release-now?
       (define fires '())
       (dynamic-wind
        void
        (lambda ()
          ;; A loop-adopted host: end stepping and join the park thread
          ;; OUTSIDE the host lock, before native teardown — the park thread
          ;; takes this same lock to step, so joining it under the lock
          ;; would deadlock.
          (let ([lp (host-loop-of m)])
            (when lp ((unbox loop-prestop-hook) lp)))
          (set!
           fires
           (call-with-host/allow-released
            m
            (lambda ()
              (let ([close! (unbox close-session-hook)])
                (when (and close-sessions? close!)
                  (for ([c (in-list (hash-values (host-sessions m)))]) (close! c))))
              ;; A refusal leaves the wrapper live. Only successful native
              ;; teardown invalidates the pointer and crosses terminal state.
              (let* ([ptr (host-ptr m)]
                     [lp (host-loop-of m)]
                     [fail-vows! (unbox fail-host-vows-hook)])
                (if lp
                    ((unbox loop-native-release-hook) lp)
                    (check/host (pancake_host_release ptr)))
                (trace-detach-host! m)
                (set-host-ptr! m #f)
                (set-box! (host-released? m) #t)
                (let ([pending-fires
                       (if fail-vows!
                           (fail-vows! m "host released")
                           (begin (hash-clear! (host-vows m)) '()))])
                  (hash-clear! (host-keep m))
                  (hash-clear! (host-sessions m))
                  pending-fires))))))
       (lambda () (hash-remove! host-release-active m)))
       (for ([fire (in-list fires)])
         (with-handlers ([(lambda (_e) #t) void]) (fire))))]))

;; ── The reentrant host lock ───────────────────────────────────────────────────
;; One thread (or one green-thread scheduler) drives one host; nothing in the C
;; tier locks. Racket green threads preempt between expressions, so this lock is
;; what serializes a whole verb-plus-drain sequence against the other threads
;; sharing the host (a server's accepted sessions, a gifter's exporter
;; dial). Reentrant by owner thread: a behavior fired inside a locked feed
;; drain calls enqueueing host verbs of its own (a hosted turn's `session-tell`
;; or spawn), and those inner entries must not self-deadlock.
(define (call-with-host* m on-released thunk)
  (define owner (host-lock-owner m))
  (define (run)
    (cond
      [(unbox (host-released? m)) (on-released)]
      [else (thunk)]))
  (cond
    [(eq? (unbox owner) (current-thread)) (run)]
    [else
     (call-with-semaphore
      (host-lock m)
      (lambda ()
        (set-box! owner (current-thread))
        ;; The released check belongs inside the lock. A sibling may have
        ;; completed teardown while this thread was parked on the semaphore.
        (dynamic-wind void run (lambda () (set-box! owner #f)))))]))

(define (call-with-host m thunk)
  (call-with-host*
   m
   (lambda () (raise-pancake 'host ERR-CLOSED "host released"))
   thunk))

;; Release is idempotent, including two callers that race for the host lock.
;; The second observes terminal state in the serialized region and has no work.
(define (call-with-host/allow-released m thunk)
  (call-with-host* m (lambda () '()) thunk))

;; Cleanup paths still need the lock after terminal transition so they can
;; observe that state and retire binding-owned queues without touching native
;; authority. Ordinary operations use `call-with-host`; release uses the
;; idempotent variant above.
(define (call-with-host/terminal m thunk)
  (call-with-host* m thunk thunk))

;; The trace registry holds Hosts weakly and reaches native state only through
;; this installer. Its strong owner snapshot prevents finalization during the
;; call; this lock serializes an install or uninstall against explicit release.
(define (host-install-trace! m callback ctx)
  (call-with-host/terminal
   m
   (lambda ()
     (define ptr (host-ptr m))
     (when ptr (check/host (pancake_host_set_trace ptr callback ctx))))))

;; ── Progress: how a parked pump notices another thread's work ─────────────────
;; `host-progress-evt` is an event that fires when any host progress has been
;; made since it was read; a pump snapshots it, re-checks its predicate, then
;; waits on the snapshot together with its own transport. `semaphore-peek-evt`
;; wakes every waiter without consuming the post.
;;
;; Snapshot and bump both run under the host lock so a waiter cannot observe a
;; generation the holder already retired between a failed reader CAS and the
;; wait — that schedule left the waiter on an unposted semaphore forever.
(define (host-progress-evt m)
  (call-with-host m
    (lambda () (semaphore-peek-evt (unbox (host-progress m))))))

(define (host-bump-progress! m)
  ;; A terminal cleanup drain still has to wake pumps that observed the prior
  ;; generation. This mutates only Racket-owned scheduler state, so it remains
  ;; valid after the native host pointer is gone.
  (call-with-host/terminal m
    (lambda ()
      (define old (unbox (host-progress m)))
      (set-box! (host-progress m) (make-semaphore 0))
      (semaphore-post old)
      (void))))

;; ── Callback retention ────────────────────────────────────────────────────────
;; Strongly retain `cb` (a behavior closure whose C trampoline the host
;; holds); `host-retire!` drops a row a refused mint never installed. An
;; accepted behavior lives as long as its host. Settlements retain nothing;
;; they ride the action queue.
(define (host-retain! m cb) (hash-set! (host-keep m) cb #t))
(define (host-retire! m cb) (hash-remove! (host-keep m) cb))

;; ── Session registry ──────────────────────────────────────────────────────────
(define (session-key ptr) (cast ptr _pointer _uintptr))
(define (host-register-session! m ptr c) (hash-set! (host-sessions m) (session-key ptr) c))
(define (host-unregister-session! m ptr) (hash-remove! (host-sessions m) (session-key ptr)))
(define (host-session-for-ptr m ptr) (hash-ref (host-sessions m) (session-key ptr) #f))

;; The live `session` homing remote capability `ref`. A local, stale,
;; foreign-Host, or closed-session capability answers #f. Binding-internal;
;; `session-send-redeeming` suppresses its own sending session and surfaces only
;; a different exporter.
;;
;; The answer comes from the reference's own routing token, not from whichever
;; exporter this host dialed most recently, so it is exact with several redeems
;; in flight at once. It is also a lookup rather than a dial: a reference whose
;; exporter an earlier redeem already reached resolves to that same live
;; session and opens no second session.
(define (host-exporter-for m ref)
  (define ptr
    (call-with-host m
      (lambda ()
        (define-values (rc p) (pancake_host_reference_exporter (host-ptr m) (ref->c ref)))
        (check/host rc)
        p)))
  (and ptr
       (or (host-session-for-ptr m ptr)
           ;; A loop-owned host redeems handoffs inside its own steps
           ;; (ADR-0112), so the exporter session it dialed exists with no
           ;; wrapper yet. Wrap it lazily — the wrap registers it, so a
           ;; repeat lookup answers this same object — and the loop stays
           ;; its release authority.
           (let ([lp (host-loop-of m)])
             (and lp ((unbox loop-wrap-session-hook) lp ptr))))))

;; Releases the C tier refused inside a behavior callback park here
;; (`pancake_host_session_release` is refused mid-turn); the drain runs them once
;; the enclosing feed unwinds, so a mid-turn `session-close!` never leaks its
;; C handle. Mirrors Python/Rust/TS.
(define host-parked-releases (make-hasheq))

(define (host-park-release! m thunk)
  (hash-update! host-parked-releases m (lambda (xs) (cons thunk xs)) '()))

(define (host-drain-parked-releases! m)
  (unless (inside-turn?)
    (define thunks (hash-ref host-parked-releases m '()))
    (hash-remove! host-parked-releases m)
    (for-each (lambda (t) (t)) (reverse thunks))))

(define (host-pending-release-count m)
  (length (hash-ref host-parked-releases m '())))

;; ── Host verbs the drain loop answers actions with ───────────────────────────
;; Decode and the drain switch (`drain-host-actions!`) live in
;; `private/action.rkt`. The verbs below are what those arms call.

;; Answer a NEED_GIFT_ID action: entropy is a host effect, drawn only when a
;; reply actually becomes a gift. The host originates the claimed handoff and
;; flushes its legs, exporter first. Caller holds the host lock.
(define (host-provide-gift-id! m ticket)
  (with-handlers ([exn:fail?
                   (lambda (_e)
                     (check/host (pancake_host_gift_id_failed (host-ptr m) ticket)))])
    (define id (crypto-random-bytes 32))
    (check/host (pancake_host_provide_gift_id (host-ptr m) ticket (pin-immobile id) 32))))

;; Report a DIAL action's outcome. Caller holds the host lock.
(define (host-dialed! m ticket session-ptr)
  (check/host (pancake_host_dialed (host-ptr m) ticket session-ptr)))

(define (host-dial-failed! m ticket reason)
  (define bs (string->bytes/utf-8 reason))
  (check/host (pancake_host_dial_failed (host-ptr m) ticket (pin-immobile bs) (bytes-length bs))))

;; Retain and select this Host's complete acceptable location.
(define (host-set-advertised-locator! m loc)
  (call-with-locator-view
   loc
   (lambda (view)
     (call-with-host m
       (lambda ()
         (check/host (pancake_host_set_advertised_locator (host-ptr m) view)))))))

;; Retain a transport location without displacing an acceptable location
;; already selected for another transport.
(define (host-ensure-advertised-locator! m transport)
  (define bs (string->bytes/utf-8 transport))
  (call-with-host m
    (lambda ()
      (check/host (pancake_host_ensure_advertised_locator
                   (host-ptr m) (pin-immobile bs) (bytes-length bs))))))

(define (host-remove-advertised-locator! m transport)
  (define bs (string->bytes/utf-8 transport))
  (call-with-host m
    (lambda ()
      (check/host (pancake_host_remove_advertised_locator
                   (host-ptr m) (pin-immobile bs) (bytes-length bs))))))

;; Selective session-limit knobs (ADR-0082). Pass 0 to leave a field unchanged.
;; Affects peers minted after this call.
(define (host-set-session-limits! m max-frame-bytes queue-cap [outbound-high-water-bytes 0])
  (call-with-host m
    (lambda ()
      (check/host (pancake_host_set_session_limits
                   (host-ptr m)
                   max-frame-bytes
                   queue-cap
                   outbound-high-water-bytes)))))

;; Derive the canonical key designator (64 lowercase hex digits) from a 32-byte
;; Ed25519 identity seed — the public half of the key a host signs with
;; (ADR-0075).
(define (designator-from-seed seed)
  (unless (= (bytes-length seed) 32)
    (raise-pancake 'designator-from-seed ERR-INVALID-ARGUMENT
                   "seed must be 32 bytes"))
  ;; Output buffer is mutable Racket bytes the FFI writes into — do not
  ;; `pin-immobile` it (that copies, and the write would be discarded). Plain
  ;; bytes are safe here only because this call is not marked `#:blocking?`, so
  ;; the collector cannot run and move the block under it; a blocking call needs
  ;; `out-immobile` instead.
  (define out (make-bytes 64))
  (check/host (pancake_host_designator_from_seed (pin-immobile seed) 32 out 64))
  (bytes->string/utf-8 out))

;; ── Host-wide giftables ───────────────────────────────────────────────────────
;; Host `behavior` once and bind `name` as a Host-wide alias. Fetch lazily
;; projects the actor onto a session; a deposited gift keeps that exact actor
;; when a recipient withdraws over its own exporter session. The binding keeps
;; the trampoline alive. The behavior is an ordinary actor behavior
;; `(lambda (method . args) …)`, e.g. one built with `methods`.
(define (host-publish-giftable m name behavior)
  (define tramp (make-giftable-trampoline behavior))
  (host-retain! m tramp)
  (define nb (string->bytes/utf-8 name))
  ;; The host never owns the row (the free callback is #f), so a refused
  ;; publish must retire the retained closure or it leaks for the host's life.
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (host-retire! m tramp) (raise e))])
    (call-with-host m
      (lambda ()
        (check/host (pancake_host_publish (host-ptr m) (pin-immobile nb) (bytes-length nb)
                                          tramp #f #f))))))

;; Remove the Host-wide alias `name` (alias-only): a later fetch misses on
;; every session, while issued refs and deposited gifts keep the exact actor,
;; whose retained trampoline stays hosted for the host's life. Returns #f when
;; no such alias exists.
(define (host-unpublish-giftable m name)
  (define nb (string->bytes/utf-8 name))
  (call-with-host m
    (lambda ()
      (define rc (pancake_host_unpublish (host-ptr m) (pin-immobile nb) (bytes-length nb)))
      (cond
        [(= rc ERR-NOT-FOUND) #f]
        [else (check/host rc) #t]))))

;; Publish `behavior` under a freshly minted durable swiss name (ADR-0098) and
;; return that name — the swiss to place in a sturdyref beside this host's own
;; locator. The name is unpredictable, never reassigned, structurally disjoint
;; from every mutable alias, and removable only through `host-remove-durable`.
;; Entropy is drawn here, from the OS RNG.
(define (host-publish-durable m behavior)
  (define tramp (make-giftable-trampoline behavior))
  (host-retain! m tramp)
  (define entropy (crypto-random-bytes 16))
  ;; Output buffer is mutable Racket bytes the FFI writes into — do not
  ;; `pin-immobile` it (that copies, and the write would be discarded). Plain
  ;; bytes are safe here only because this call is not marked `#:blocking?`, so
  ;; the collector cannot run and move the block under it; a blocking call needs
  ;; `out-immobile` instead.
  (define out (make-bytes 64))
  ;; The host never owns the row (the free callback is #f), so a refused
  ;; publish must retire the retained closure or it leaks for the host's life.
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (host-retire! m tramp) (raise e))])
    (call-with-host m
      (lambda ()
        (define written
          (pancake_host_publish_durable (host-ptr m)
                                        (pin-immobile entropy) (bytes-length entropy)
                                        tramp #f #f
                                        out (bytes-length out)))
        (when (<= written 0) (check/host written))
        (bytes->string/utf-8 (subbytes out 0 written))))))

;; Remove a minted durable publication (ADR-0098): the old sturdyref misses
;; from now on, while issued refs and deposited gifts keep the exact actor.
;; Returns #f when no such durable name exists.
(define (host-remove-durable m swiss)
  (define sb (string->bytes/utf-8 swiss))
  (call-with-host m
    (lambda ()
      (define rc (pancake_host_remove_durable (host-ptr m) (pin-immobile sb) (bytes-length sb)))
      (cond
        [(= rc ERR-NOT-FOUND) #f]
        [else (check/host rc) #t]))))

;; ── The hint-less iroh redeem posture ─────────────────────────────────────────
;; The iroh reachability posture this host uses to redeem a hint-less handoff
;; give — one whose exporter location names the exporter by node id alone, so
;; the recipient must resolve it by id. Defaults to Discovery (1), the
;; maximal-reach choice; a relay-policy host lowers it to DiscoveryNoRelay. A
;; hinted give always dials Direct and ignores it. Stored as the numeric value
;; so the core stays free of the iroh companion.
(define (host-redeem-reachability-value m) (unbox (host-redeem-reachability m)))
(define (set-host-redeem-reachability! m reachability)
  (set-box! (host-redeem-reachability m) reachability))

;; The keyed-relay rendezvous mapping (ADR-0088): a procedure from the peer's
;; key designator to the relay rendezvous WebSocket URL that bridges onto its
;; held inbound socket — the keyed-relay sibling of the redeem-reachability
;; posture above. #f until configured; a keyed-relay dial refuses without it.
(define (host-rendezvous-url-value m) (unbox (host-rendezvous-url m)))
(define (set-host-rendezvous-url! m url-of)
  (set-box! (host-rendezvous-url m) url-of))
