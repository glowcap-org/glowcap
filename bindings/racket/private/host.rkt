#lang racket/base
;; Internal: the CapTP `host` — binding wrapper for `PancakeHost` /
;; `driver_core.Host` (ADR-0072 / ADR-0079). The host owns an `engine.Node`
;; (the sans-io handoff router). Goblins `mycapn` is two roles, not one type:
;; the endpoint is this host; the router tables are `engine.Node`. What lives
;; here is only what the embedder contract leaves to the binding: the host
;; handle and its reentrant lock (one green-thread scheduler drives one host,
;; and the lock is what makes "one at a time" true across this binding's
;; threads), the conn-pointer → session registry the action drain routes by,
;; the giftable trampolines' strong retention, gift-id entropy, and the iroh
;; redeem-reachability posture the dial executor reads. Action decode +
;; execute (`drain-host-actions!` via `pancake_host_pump_drain`) live in
;; `private/action.rkt`; the dial executor lives in `private/dial.rkt`;
;; the conn byte path lives in `private/pump.rkt`.

(require ffi/unsafe
         racket/random
         "constants.rkt"
         "ffi-shared.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "codec.rkt"
         "trampoline.rkt")

(provide (all-defined-out))

;; Every session's maximum admissible frame; mirrors PANCAKE_DEFAULT_FRAME_CAP.
(define HOST-FRAME-CAP DEFAULT-FRAME-CAP)

;; The host. `ptr` is the PancakeHost handle; `lock`/`lock-owner` form the
;; reentrant host lock every `pancake_host_*` verb and action drain runs under;
;; `sessions` maps a conn pointer's address to its live `session` (the FLUSH
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
;; `released?` guards the handle against use after release.
(struct host (ptr lock lock-owner sessions progress keep vows redeem-reachability released? codec))

;; `#:codec` is the wire grammar every session this host mints negotiates
;; in ('syrup by default, 'capnp for a Cap'n Proto session); both ends of a
;; session must carry the same codec. The host remembers the symbol so
;; `connect` can refuse an explicit codec that conflicts with a shared host's.
(define (make-host seed #:codec [codec 'syrup] #:local-turn-budget [local-turn-budget 0])
  (define sbuf (pin-immobile seed)) ; pin: the GC may move `seed` mid-call
  (define-values (rc ptr) (pancake_host_new sbuf 32 HOST-FRAME-CAP 1 (codec-id codec) local-turn-budget))
  (check/host rc)
  (define m (host ptr (make-semaphore 1) (box #f) (make-hash) (box (make-semaphore 0))
                  (make-hasheq) (make-hash) (box IROH-REACH-REDEEM-DEFAULT) (box #f) codec))
  (register-finalizer m (lambda (q) (host-release! q #:close-sessions? #f)))
  m)

;; A host with a fresh random identity seed — entropy drawn at the binding
;; boundary, never inside the sans-io host.
(define (make-fresh-host #:codec [codec 'syrup] #:local-turn-budget [local-turn-budget 0])
  (make-host (crypto-random-bytes 32) #:codec codec #:local-turn-budget local-turn-budget))

;; How `host-release!` closes the sessions it still holds. `session.rkt` fills
;; this in when it loads: it requires this module for CapTP verbs, so the
;; import only runs one way and this module cannot name `session-close!`.
(define close-session-hook (box #f))

;; Hosts whose explicit release was requested from inside a native callback.
;; Pending is still live and must not suppress the finalizer.
(define host-release-pending (make-hasheq))

;; Release the host and everything it owns: close every session it still
;; holds — the ones an application opened and the ones the host dialed to
;; redeem handoffs alike — then free the handle. Closing a session closes that
;; one connection; this is what closes the rest.
;;
;; `close-sessions?` is #f on the finalizer path. A finalizer runs on the
;; collector's own thread, where touching a port is not safe, and a host being
;; collected has no reachable sessions left for anyone to observe.
(define (host-release! m #:close-sessions? [close-sessions? #t])
  (call-with-host
   m
   (lambda ()
     (unless (unbox (host-released? m))
       (cond
         [(inside-turn?)
          (unless (hash-ref host-release-pending m #f)
            (hash-set! host-release-pending m #t)
            (host-park-release!
             m
             (lambda ()
               (hash-remove! host-release-pending m)
               (host-release! m #:close-sessions? close-sessions?))))]
         [else
          (let ([close! (unbox close-session-hook)])
            (when (and close-sessions? close!)
              ;; `hash-values` snapshots, so each close unregistering itself
              ;; from the table does not disturb the walk.
              (for ([c (in-list (hash-values (host-sessions m)))]) (close! c))))
          ;; A refusal leaves the wrapper live. Only successful native teardown
          ;; drops Racket's strong edges and crosses the terminal state.
          (check/host (pancake_host_release (host-ptr m)))
          (hash-clear! (host-keep m))
          (hash-clear! (host-vows m))
          (hash-clear! (host-sessions m))
          (set-box! (host-released? m) #t)])))))

;; ── The reentrant host lock ───────────────────────────────────────────────────
;; One thread (or one green-thread scheduler) drives one host; nothing in the C
;; tier locks. Racket green threads preempt between expressions, so this lock is
;; what serializes a whole verb-plus-drain sequence against the other threads
;; sharing the host (a server's accepted sessions, a gifter's exporter
;; dial). Reentrant by owner thread: a behavior fired inside a locked feed
;; drain calls enqueueing host verbs of its own (a hosted turn's `session-tell`
;; or spawn), and those inner entries must not self-deadlock.
(define (call-with-host m thunk)
  (define owner (host-lock-owner m))
  (cond
    [(eq? (unbox owner) (current-thread)) (thunk)]
    [else
     (call-with-semaphore
      (host-lock m)
      (lambda ()
        (set-box! owner (current-thread))
        (dynamic-wind void thunk (lambda () (set-box! owner #f)))))]))

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
  (call-with-host m
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
(define (conn-key ptr) (cast ptr _pointer _uintptr))
(define (host-register-session! m ptr c) (hash-set! (host-sessions m) (conn-key ptr) c))
(define (host-unregister-session! m ptr) (hash-remove! (host-sessions m) (conn-key ptr)))
(define (host-session-for-ptr m ptr) (hash-ref (host-sessions m) (conn-key ptr) #f))

;; The live `session` homing remote capability `ref`. A local, stale,
;; foreign-Host, or closed-session capability answers #f. Binding-internal;
;; `session-send-redeeming` suppresses its own sending session and surfaces only
;; a different exporter.
;;
;; The answer comes from the reference's own routing token, not from whichever
;; exporter this host dialed most recently, so it is exact with several redeems
;; in flight at once. It is also a lookup rather than a dial: a reference whose
;; exporter an earlier redeem already reached resolves to that same live
;; session and opens no second connection.
(define (host-exporter-for m ref)
  (define ptr
    (call-with-host m
      (lambda ()
        (define-values (rc p) (pancake_host_reference_exporter (host-ptr m) (ref->c ref)))
        (check/host rc)
        p)))
  (and ptr (host-session-for-ptr m ptr)))

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
  (define id (crypto-random-bytes 32))
  (check/host (pancake_host_provide_gift_id (host-ptr m) ticket (pin-immobile id) 32)))

;; Report a DIAL action's outcome. Caller holds the host lock.
(define (host-dialed! m ticket conn-ptr)
  (check/host (pancake_host_dialed (host-ptr m) ticket conn-ptr)))

(define (host-dial-failed! m ticket reason)
  (define bs (string->bytes/utf-8 reason))
  (check/host (pancake_host_dial_failed (host-ptr m) ticket (pin-immobile bs) (bytes-length bs))))

;; Record the designator this host's dials sign as their own dialable address
;; (a host that also listens); `listen` / `listen-iroh` set it to the bound
;; address so a partner's crossed-hellos table can recognize this host.
(define (host-set-self-designator! m designator)
  (define bs (string->bytes/utf-8 designator))
  (call-with-host m
    (lambda ()
      (check/host (pancake_host_set_self_designator (host-ptr m) (pin-immobile bs) (bytes-length bs))))))

;; Selective session-limit knobs (ADR-0082). Pass 0 to leave a field unchanged.
;; Affects peers minted after this call.
(define (host-set-session-limits! m max-frame-bytes queue-cap)
  (call-with-host m
    (lambda ()
      (check/host (pancake_host_set_session_limits (host-ptr m) max-frame-bytes queue-cap)))))

;; Derive the canonical key designator (64 lowercase hex digits) from a 32-byte
;; Ed25519 identity seed — the public half of the key a host signs with
;; (ADR-0075).
(define (designator-from-seed seed)
  (unless (= (bytes-length seed) 32)
    (raise-pancake 'designator-from-seed ERR-INVALID-ARGUMENT
                   "seed must be 32 bytes"))
  ;; Output buffer is mutable Racket bytes the FFI writes into — do not
  ;; `pin-immobile` it (that copies, and the write would be discarded).
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
