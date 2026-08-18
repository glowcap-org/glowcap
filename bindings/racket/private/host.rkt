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
         "ffi-ocapn.rkt"
         "ffi-shared.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "finalizer-diagnostics.rkt"
         "locator.rkt"
         "trace.rkt"
         "abi-value.rkt"
         "trampoline.rkt"
         "transport.rkt")

(provide (all-defined-out))

;; Every session's maximum admissible frame; mirrors PANCAKE_DEFAULT_FRAME_CAP.
(define HOST-FRAME-CAP DEFAULT-FRAME-CAP)

(define (monotonic-ms)
  (inexact->exact (floor (current-inexact-monotonic-milliseconds))))

(define grace-unspecified (gensym 'grace-unspecified))

(define (close-options who pending grace-ms)
  (define pending-id
    (case pending
      [(cancel) PENDING-CANCEL]
      [(finish) PENDING-FINISH]
      [else #xffffffff]))
  (define-values (grace-mode grace-value)
    (cond
      [(eq? grace-ms grace-unspecified) (values CLOSE-GRACE-UNSPECIFIED 0)]
      [(not grace-ms) (values CLOSE-GRACE-UNBOUNDED 0)]
      [(and (exact-nonnegative-integer? grace-ms) (<= grace-ms CLOSE-MAX-GRACE-MS))
       (values CLOSE-GRACE-FINITE grace-ms)]
      [else
       (raise-pancake who ERR-INVALID-ARGUMENT
                      (format "#:grace-ms must be #f or an integer from 0 through ~a"
                              CLOSE-MAX-GRACE-MS))]))
  (make-PancakeCloseOptions CLOSE-OPTIONS-ABI-VERSION
                            (ctype-sizeof _PancakeCloseOptions)
                            pending-id
                            grace-mode
                            grace-value))

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
   (lambda () (check (pancake_context_report_failure (host-context m) report)))))

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

;; Release one native session handle through its owner: the loop for a
;; loop-adopted host, `pancake_host_session_release` for a byte-fed one.
(define (native-session-release! m ptr)
  (define lp (host-loop-of m))
  (if lp
      ((unbox loop-session-release-hook) lp ptr)
      (check/host (pancake_host_session_release ptr))))

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
  (define-values (context-rc context) (pancake_context_new))
  (check context-rc)
  (define-values (rc ptr)
    (pancake_host_new_in context sbuf 64 HOST-FRAME-CAP 1 (codec-id codec)
                        (captp-version-id captp-version) (feature-mask features)
                        local-turn-budget))
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (pancake_context_release context)
                     (raise error))])
    (check/host rc))
  (define-values (identity-rc diagnostic-id) (pancake_host_diagnostic_id ptr))
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (define cleanup-code (pancake_host_release ptr))
                     (define cleanup
                       (with-handlers ([(lambda (_) #t) values])
                         (check/host cleanup-code)
                         #f))
                     ;; A pre-commit refusal leaves a native Host borrowing
                     ;; this Context. Leak the pair rather than free its
                     ;; allocator policy under the still-live Host.
                     (when (release-consumed? cleanup-code)
                       (pancake_context_release context))
                     (raise (if cleanup
                                (retain-cleanup-failure error cleanup)
                                error)))])
    (check/host identity-rc))
  (define m (host ptr context diagnostic-id durable-seed (make-semaphore 1) (box #f) (make-hash) (box (make-semaphore 0))
                  (make-hasheq) (make-hash) (make-hash) (box IROH-REACH-REDEEM-DEFAULT) (box #f) (box #f) (box #f) codec captp-version features (box #f) (make-hash)))
  ;; The host's own key designator, which is what a partner names it by: the
  ;; live trace reports it as this host's endpoint so one peer stays one node
  ;; in a feed several producers share.
  (trace-attach-host!
   m host-install-trace! (designator-from-seed durable-seed)
   (lambda (operation error)
     (host-record-callerless-failure! m operation error)))
  (register-finalizer m host-finalize!)
  m)

;; A host with a fresh random identity seed — entropy drawn at the binding
;; boundary, never inside the sans-io host.
(define (make-fresh-host #:codec [codec 'syrup] #:captp-version [captp-version 'v1_0]
                         #:features [features 'full]
                         #:local-turn-budget [local-turn-budget 0])
  (make-host (crypto-random-bytes 32) #:codec codec #:captp-version captp-version
             #:features features
             #:local-turn-budget local-turn-budget))

;; A close requested inside a native callback records policy in native state
;; immediately. This set retains only which Host needs its release executor
;; after the callback unwinds; it never mirrors or replays close policy.
(define host-release-pending (make-hasheq))

;; One shared completion barrier per Host release. Repeated explicit close
;; forwards its request to native state, then joins this barrier and observes
;; the same result as the executor.
(struct release-barrier (done result [worker #:mutable]) #:transparent)
(struct release-result (error) #:transparent)
(define host-release-active (make-hasheq))

(define (publish-host-release! m barrier outcome)
  ;; Once the native pointer moves, result publication and waiter wakeup are one
  ;; uninterruptible binding transition. Remove only this barrier: a failed
  ;; worker may already have allowed a later caller to install its retry.
  (parameterize-break
   #f
   (set-box! (release-barrier-result barrier) outcome)
   (set-box! (host-close-result m) outcome)
   (call-with-host/terminal
    m
    (lambda ()
      (when (eq? (hash-ref host-release-active m #f) barrier)
        (hash-remove! host-release-active m))))
   (semaphore-post (release-barrier-done barrier))))

(define (run-host-release-worker! m barrier close-sessions?)
  (define outcome
    (with-handlers ([(lambda (_) #t)
                     (lambda (error)
                       (record-host-runtime-failure! m error)
                       (release-result (host-runtime-primary m)))])
      (define close-code OK)
      (dynamic-wind
       void
       (lambda ()
         (let ([lp (host-loop-of m)])
           (when close-sessions?
             (set! close-code
                   (if lp
                       ((unbox loop-close-barrier-hook) lp)
                       ((unbox host-close-barrier-hook) m)))
             (unless (or (= close-code OK) (= close-code ERR-TIMEOUT))
               (check/host close-code)))
           ;; Stop stepping and join the park thread OUTSIDE the host lock,
           ;; after the native barrier projected every terminal event.
           (when lp ((unbox loop-prestop-hook) lp close-sessions?)))
         (call-with-host/allow-released
          m
          (lambda ()
            ;; INVALID-ARGUMENT leaves the wrapper live. Every other result is
            ;; a consumed teardown outcome: retire wrapper/context state before
            ;; returning its exact failure from the close barrier.
            (let* ([ptr (host-ptr m)]
                   [lp (host-loop-of m)])
              (define-values (release-code release-error)
                (if lp
                    ((unbox loop-native-release-hook) lp)
                    (let ([code (pancake_host_release ptr)])
                      (values
                       code
                       (with-handlers ([(lambda (_) #t) values])
                         (check/host code)
                         #f)))))
              (when (release-consumed? release-code)
                (pancake_context_release (host-context m))
                (trace-detach-host! m)
                (set-host-ptr! m #f)
                (set-box! (host-released? m) #t)
                (hash-clear! (host-vows m))
                (hash-clear! (host-dial-workers m))
                (hash-clear! (host-keep m))
                (hash-clear! (host-sessions m)))
              (when release-error (raise release-error))))))
       void)
      (when (= close-code ERR-TIMEOUT) (check/host close-code))
      (release-result (host-runtime-primary m))))
  (publish-host-release! m barrier outcome))

;; Install the one retained worker while the caller holds the Host lock. The
;; caller decides whether to join its barrier; callback-unwind drains only
;; install it, because joining before the lock is released would deadlock the
;; worker's first close-progress step.
(define (start-host-release-worker!/locked m close-sessions?)
  (define barrier (release-barrier (make-semaphore 0) (box #f) #f))
  (hash-set! host-release-active m barrier)
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (hash-remove! host-release-active m)
                     (raise error))])
    (set-release-barrier-worker!
     barrier
     (thread (lambda () (run-host-release-worker! m barrier close-sessions?)))))
  barrier)

(define (begin-host-close/locked! m options)
  (define lp (host-loop-of m))
  (if lp
      ((unbox loop-begin-close-hook) lp options)
      (check/host (pancake_host_close (host-ptr m) options (monotonic-ms)))))

(define (drain-pending-host-release! m)
  (call-with-host/terminal
   m
   (lambda ()
     (define pending? (hash-has-key? host-release-pending m))
     (hash-remove! host-release-pending m)
     (when (and pending?
                (not (unbox (host-released? m)))
                (not (hash-ref host-release-active m #f)))
       (start-host-release-worker!/locked m #t)))))

;; The Host-wide close barrier: apply the pending-work policy, close every
;; session the host still holds (the ones an application opened and the ones
;; the host dialed to redeem handoffs alike), then free the handle. Closing a
;; session closes that one connection; this is what closes the rest. A repeated
;; call joins the in-progress barrier or re-observes the retained terminal
;; outcome, a finish grace timeout included.
(define (host-close! m
                     #:pending [pending 'cancel]
                     #:grace-ms [grace-ms grace-unspecified])
  (host-release/options! m (close-options 'host-close! pending grace-ms) #t))

;; Native loop retirement has already crossed its close barrier. Release the
;; loop/Host allocation without beginning a second policy request.
(define (host-release-after-native-close! m)
  (host-release/options! m #f #f))

;; A failed loop has already stopped ordinary stepping, so it cannot drive a
;; second native close policy. Install its memory-only release barrier before
;; returning to the failing park/retirement thread, but leave that thread free
;; to exit: the release worker joins it during `loop-prestop!`.
(define (host-release-after-native-close/async! m)
  (call-with-host/terminal
   m
   (lambda ()
     (parameterize-break
      #f
      (unless (or (unbox (host-released? m))
                  (hash-ref host-release-active m #f))
        (start-host-release-worker!/locked m #f)))))
  (void))

;; A finalizer runs on the collector's thread, where touching a port is unsafe.
;; An unreachable Host has no reachable session wrapper; native release owns
;; the remaining physical cleanup.
(define (host-finalize! m)
  (run-native-finalizer!
   "host.finalizer.release"
   (lambda () (host-release/options! m #f #f))))

(define (host-release/options! m options close-sessions?)
  (define disposition
    (call-with-host/terminal
     m
     (lambda ()
       ;; No break may land between the native request and installing its one
       ;; retained driver. The worker itself remains interruptible while it
       ;; waits; only its terminal publication is protected.
       (parameterize-break
        #f
        (cond
          ;; A policy request against a released Host re-observes the retained
          ;; terminal outcome; memory-only release and the finalizer stay
          ;; silent, because the collector's thread must never raise.
          [(unbox (host-released? m))
           (if options
               (list 'observed (unbox (host-close-result m)))
               '(released))]
          [(hash-ref host-release-active m #f)
           => (lambda (barrier)
                (when (and options (not (unbox (host-released? m))))
                  (begin-host-close/locked! m options))
                (if (inside-turn?) '(deferred) (list 'wait barrier)))]
          [(inside-turn?)
           ;; Native close records the admission barrier under the callback latch;
           ;; only effect driving and release wait for the enclosing turn to unwind.
           (when options (begin-host-close/locked! m options))
           (define already-pending? (hash-has-key? host-release-pending m))
           (hash-set! host-release-pending m #t)
           (unless already-pending?
             (host-park-release! m (lambda () (drain-pending-host-release! m))))
           '(deferred)]
          [else
           (when options (begin-host-close/locked! m options))
           (list 'wait (start-host-release-worker!/locked m close-sessions?))])))))
  ;; A close request issued outside a turn is close-relevant activity: a
  ;; driver already parked on host progress with no finite deadline must
  ;; re-check. A mid-turn request needs no bump here, because the enclosing
  ;; drain bumps when the turn unwinds; bumping earlier lets the turn's own
  ;; pump observe closure before the parked release executes.
  (when (eq? (car disposition) 'wait) (host-bump-progress! m))
  (case (car disposition)
    [(released deferred) (void)]
    [(observed)
     (define result (cadr disposition))
     (when (and result (release-result-error result))
       (raise (release-result-error result)))]
    [(wait)
     (define barrier (cadr disposition))
     (sync (semaphore-peek-evt (release-barrier-done barrier)))
     (define result (unbox (release-barrier-result barrier)))
     (when (release-result-error result) (raise (release-result-error result)))]))

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
