#lang racket/base
;; Internal: the Racket-owned state and mediation authority for a CapTP Host.
;; Native close policy and Host verbs stay in ../host.rkt; this leaf owns only
;; binding state, serialization, diagnostics, loop selection, and registries.

(require ffi/unsafe
         "../constants.rkt"
         "../ffi-ocapn.rkt"
         "../ffi-host.rkt"
         "../errors.rkt"
         "../finalizer-diagnostics.rkt"
         "../abi-value.rkt"
         "../transport.rkt")

(provide (all-defined-out))

(define (monotonic-ms)
  (inexact->exact (floor (current-inexact-monotonic-milliseconds))))

;; The host. `ptr` is the PancakeHost handle; `lock`/`lock-owner` form the
;; reentrant host lock every `pancake_host_*` verb and action drain runs under;
;; `sessions` maps a session pointer's address to its live `session` (the FLUSH
;; action's routing table, and what keeps redeem-dialed exporter sessions
;; alive); `progress` boxes the generation semaphore pumps wait on — bumped
;; after every locked host operation, so a thread parked on one session
;; notices a settle another session's feed fired; `keep` strongly retains
;; every behavior closure registered with the host (a C trampoline stays alive
;; only while its Racket closure does); `vows` maps a host vow id to the
;; weak box for the `session-vow` awaiting it, filled at mint under the host
;; lock and settled by the drain's SETTLE/FAIL arms (`private/promise.rkt`). A
;; dropped pending wrapper can therefore reach its release finalizer; no
;; callback crosses the C boundary for a settlement. `redeem-reachability` is the
;; iroh posture a hint-less handoff give is redeemed under (starting at the
;; generated `IROH-REACH-REDEEM-DEFAULT`, Discovery;
;; `set-host-redeem-reachability!` lowers it for a relay-policy deployment);
;; `runtime-failure` is the first exception from Host-owned background work
;; (notably a redeemed exporter session's serve thread); `close-result` boxes
;; the terminal close outcome once release crosses
;; terminal state, so a repeated `host-close!` re-observes it (a finish grace
;; timeout included) instead of silently succeeding;
;; `released?` guards the handle against use after release; `driver-loop`
;; boxes the native loop this host is adopted over (ADR-0112), or #f for a
;; byte-fed host — when set, the action drain, session release, and host
;; release all route through the loop via the hooks below.
(struct host ([ptr #:mutable] context diagnostic-id seed lock lock-owner sessions progress keep vows dial-workers redeem-reachability runtime-failure close-result released? codec captp-version features driver-loop connectors))

;; One exact primary plus the first exact consequence and total consequence
;; count. This is the binding attachment behind the shared diagnostic shape;
;; explicit Host close remains the deterministic observing barrier.
(struct terminal-failure-chain (primary secondary secondary-count) #:transparent)

(define (record-host-runtime-failure! m error)
  (let loop ()
    (define old (unbox (host-runtime-failure m)))
    (cond
      [(and old
            (or (eq? error (terminal-failure-chain-primary old))
                (eq? error (terminal-failure-chain-secondary old))))
       (terminal-failure-chain-primary old)]
      [else
       (define next
         (if old
             (terminal-failure-chain
              (terminal-failure-chain-primary old)
              (or (terminal-failure-chain-secondary old) error)
              (min #xffffffff
                   (add1 (terminal-failure-chain-secondary-count old))))
             (terminal-failure-chain error #f 0)))
       (if (box-cas! (host-runtime-failure m) old next)
           (terminal-failure-chain-primary next)
           (loop))])))

(define (host-runtime-primary m)
  (define failure (unbox (host-runtime-failure m)))
  (and failure (terminal-failure-chain-primary failure)))

;; The native loop this host is adopted over, or #f. The one branch point
;; every loop-aware seam reads.
(define (host-loop-of m) (unbox (host-driver-loop m)))

;; A byte-fed Host is the owner of the explicit connector registry used by
;; handoff redemption. Registration is keyed by the locator's transport symbol
;; so a connector cannot accidentally answer for a different transport.
(define (host-register-connector! m connector)
  (unless (byte-connector? connector)
    (raise-argument-error 'host-register-connector! "byte-connector?" connector))
  (for ([transport (in-list (byte-connector-transports connector))])
    (hash-set! (host-connectors m) transport connector))
  connector)

(define (host-connector-for m transport)
  (call-with-host m (lambda () (hash-ref (host-connectors m) transport #f))))

(define failure-layers '#(core driver transport binding application-observer))
(define failure-scopes '#(process context host session listener transport operation))

(define (failure-symbol vocabulary index family)
  (if (< index (vector-length vocabulary))
      (vector-ref vocabulary index)
      (error 'pancake "ABI returned unknown failure ~a: ~a" family index)))

(define (failure-text ptr len)
  (if (or (not ptr) (zero? len))
      ""
      ;; Native diagnostic reports are validated and truncated at code-point
      ;; boundaries. Invalid text here is an ABI violation, not adapter data
      ;; that the binding may silently repair.
      (bytes->string/utf-8 (bytes<-c ptr len))))

(define (next-context-failure context)
  (define event
    (make-PancakeFailureEvent 1
                              (ctype-sizeof _PancakeFailureEvent)
                              0 0 0 0 0 0 0 0 0 0
                              #f 0 #f 0 #f 0 #f 0 #f 0))
  (define-values (first required)
    (pancake_context_next_failure context event #f 0))
  (cond
    [(= first WOULD-BLOCK) #f]
    [(= first ERR-BUFFER-TOO-SMALL)
     (define payload (malloc required 'atomic))
     (define-values (rc _required)
       (pancake_context_next_failure context event payload required))
     (check rc)
     (failure-event
      (PancakeFailureEvent-sequence event)
      (PancakeFailureEvent-dropped-before event)
      (failure-symbol failure-layers (PancakeFailureEvent-layer event) 'layer)
      (failure-symbol failure-scopes (PancakeFailureEvent-scope-kind event) 'scope)
      (PancakeFailureEvent-scope-id event)
      (PancakeFailureEvent-operation-id event)
      (PancakeFailureEvent-primary-result event)
      (PancakeFailureEvent-secondary-result event)
      (PancakeFailureEvent-secondary-count event)
      (PancakeFailureEvent-flags event)
      (failure-text (PancakeFailureEvent-operation event)
                    (PancakeFailureEvent-operation-len event))
      (failure-text (PancakeFailureEvent-primary-name event)
                    (PancakeFailureEvent-primary-name-len event))
      (failure-text (PancakeFailureEvent-primary-message event)
                    (PancakeFailureEvent-primary-message-len event))
      (failure-text (PancakeFailureEvent-secondary-name event)
                    (PancakeFailureEvent-secondary-name-len event))
      (failure-text (PancakeFailureEvent-secondary-message event)
                    (PancakeFailureEvent-secondary-message-len event)))]
    [else (check first)]))

;; Atomically claim every callerless native failure currently retained by m.
(define (host-take-failures! m)
  (call-with-host
   m
   (lambda ()
     (let loop ([claimed '()])
       (define event (next-context-failure (host-context m)))
       (if event (loop (cons event claimed)) (reverse claimed))))))

(define (host-record-callerless-failure! m operation error)
  (define operation-bytes (string->bytes/utf-8 operation))
  (define name-bytes (string->bytes/utf-8 (format "~a" (or (object-name error) 'raised-value))))
  (define message-bytes
    (string->bytes/utf-8 (if (exn? error) (exn-message error) (format "~a" error))))
  (define operation-buffer (pin-immobile operation-bytes))
  (define name-buffer (pin-immobile name-bytes))
  (define message-buffer (pin-immobile message-bytes))
  (define report
    (make-PancakeFailureReport
     1 (ctype-sizeof _PancakeFailureReport)
     FAILURE-LAYER-APPLICATION-OBSERVER FAILURE-SCOPE-HOST
     (host-diagnostic-id m) 0 ERR-INTERNAL 0 0
     operation-buffer (bytes-length operation-bytes)
     name-buffer (bytes-length name-bytes)
     message-buffer (bytes-length message-bytes)
     #f 0 #f 0))
  (record-callerless-with-fallback!
   'application-observer operation error
   (lambda ()
     (define rc (pancake_context_report_failure (host-context m) report))
     ;; The report cstruct is retained as the call's argument, but it carries
     ;; only the pins' raw addresses; the sink keeps the text buffers live
     ;; for the call.
     (void/reference-sink operation-buffer name-buffer message-buffer)
     (check rc))))

;; Prefer the live Context without making failure of that recorder permission
;; to lose either the original callerless failure or the recorder refusal.
(define (record-callerless-with-fallback! layer operation error recorder)
  (with-handlers ([(lambda (_) #t)
                   (lambda (recorder-error)
                     (record-runtime-failure! layer operation error)
                     (record-runtime-failure!
                      'binding
                      (string-append operation ".diagnostic")
                      recorder-error))])
    (recorder)))

;; ── The loop hooks (ADR-0112) ────────────────────────────────────────────────
;; `loop/lifecycle.rkt` fills these at module load — a loop-adopted host exists only
;; after that module ran, so a set hook is guaranteed wherever `host-loop-of`
;; answers a loop. Hook boxes rather than requires, because the release path
;; is reachable from the FFI finalizer thread, where a lazy-require stub
;; cannot resolve a module.
;;
;; The action drain's loop arm: one bracketed zero-timeout step plus the
;; event dispatch, in place of `pancake_host_pump_drain`, which never runs
;; beside a loop.
(define loop-drain-hook (box #f))
;; Stop stepping and join the park thread, run by the Host release worker
;; OUTSIDE the host lock (the park thread takes that lock to step).
(define loop-prestop-hook (box #f))
;; Drive the native loop close policy and event projection to its terminal
;; barrier before stepping stops.
(define loop-close-barrier-hook (box #f))
;; Forward one close request to a loop already being driven. Caller holds the
;; Host lock; no lifecycle policy is interpreted here.
(define loop-begin-close-hook (box #f))
;; Native teardown in place of `pancake_host_release`: the loop releases
;; itself and the wrapped host together.
(define loop-native-release-hook (box #f))
;; A loop-owned session's release, through `pancake_driver_session_release`.
(define loop-session-release-hook (box #f))
;; Forward one loop-owned session close request while the caller holds the Host
;; lock, then await a barrier whose requests were already forwarded.
(define loop-begin-session-close-hook (box #f))
(define loop-await-session-close-hook (box #f))
;; Resolve and claim a loop-owned exporter session before constructing a
;; binding wrapper for it.
(define loop-claim-reference-exporter-hook (box #f))
;; Lazily wrap a session the loop minted internally (a redeem-dialed
;; exporter leg) as a public `session`.
(define loop-wrap-session-hook (box #f))

;; Byte-fed close driver installed by action.rkt after its drain executor is
;; available. It executes core-issued effects and returns the terminal code.
(define host-close-barrier-hook (box #f))

;; Distributed-GC state exists only after gc.rkt has loaded. Its retirement
;; hook is installed there and runs inside the Host's terminal lock after the
;; native owner has been consumed.
(define host-gc-retire-hook (box void))

;; Release one native session handle through its owner: the loop for a
;; loop-adopted host, `pancake_host_session_release` for a byte-fed one.
(define (native-session-release! m ptr)
  (define lp (host-loop-of m))
  (if lp
      ((unbox loop-session-release-hook) lp ptr)
      (check/host (pancake_host_session_release ptr))))

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
        (define wire (ref->c ref))
        (define lp (host-loop-of m))
        (if lp
            ((unbox loop-claim-reference-exporter-hook) lp wire)
            (let-values ([(rc p) (pancake_host_reference_exporter (host-ptr m) wire)])
              (check/host rc)
              p)))))
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
;; C handle. Callers must invoke this only outside a turn. Mirrors Python/Rust/TS.
(define host-parked-releases (make-hasheq))

(define (host-park-release! m thunk)
  (hash-update! host-parked-releases m (lambda (xs) (cons thunk xs)) '()))

(define (host-drain-parked-releases! m)
  (define thunks (hash-ref host-parked-releases m '()))
  (hash-remove! host-parked-releases m)
  (for-each (lambda (t) (t)) (reverse thunks)))

(define (host-pending-release-count m)
  (length (hash-ref host-parked-releases m '())))

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
