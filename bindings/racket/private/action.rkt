#lang racket/base
;; Internal: host action execute over the byte-fed host
;; (libglowcap_host, ADR-0072 / ADR-0079).
;;
;; Owns the shared C drain (`glowcap_host_pump_drain`) with sync park-only
;; hooks, then honors each parked arm (`drain-host-actions!`). The CapTP surface
;; stays in the `private/session` module family; far-vow handles live in
;; `private/promise.rkt`; the dial executor lives in `private/dial.rkt`; the
;; host handle and vow table stay in `private/host/state.rkt`.
;; Session and host require this module eagerly; this module lazy-requires
;; dial for `run-dial!` and session for close / settle helpers so the
;; session ↔ action and dial ↔ action cycles stay breakable (same pattern as
;; `pump.rkt`).

(require racket/lazy-require
         ffi/unsafe
         "constants.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "abi-value.rkt"
         "vat.rkt"
         "host.rkt"
         "host/state.rkt"
         "pump.rkt"
         "session/state.rkt"
         "host-action-gen.rkt")

;; Dial owns run-dial!; session/close owns session-close!. Promise owns settle-vow!.
;; Lazy-require
;; breaks the dial/session ↔ action and promise ↔ session cycles.
(lazy-require
 ["promise.rkt"
  (settle-vow!)]
 ["dial.rkt"
  (run-dial!)]
 ["session.rkt"
  (finish-session-close!
   retire-session-wire-failure!)])

(provide drain-host-actions!)

(struct dial-worker (thread cancelled?))

;; ── Park ──────────────────────────────────────────────────────────────────────
;; Run `glowcap_host_pump_drain` with park-only arms; return decoded actions
;; in queue order. Views are copied inside `host-decode-action!` before the
;; next pop frees them. Caller holds the host lock; arms must not await.
(define (park-host-actions! m)
  (define parked '())
  (define callback-failure #f)
  (define (arm _ctx _host action out-progressed)
    (with-handlers ([(lambda (_) #t)
                     (lambda (error)
                       (set! callback-failure error)
                       ERR-INTERNAL)])
      (define decoded (host-decode-action! action arg<-c))
      (set! parked (cons decoded parked))
      (when out-progressed
        (ptr-set! out-progressed _uint32 1))
      OK))
  (define arm-cb (function-ptr arm _GlowcapHostPumpArmFn))
  (define hooks (make-GlowcapHostPumpHooks #f arm-cb arm-cb arm-cb arm-cb arm-cb))
  (define-values (rc _drained yielded) (glowcap_host_pump_drain (host-ptr m) hooks))
  (when callback-failure
    (raise-glowcap 'glowcap ERR-INTERNAL
                   "ABI returned an invalid host action: ~a"
                   callback-failure))
  (check/host rc)
  (values (reverse parked) (not (zero? yielded))))

;; ── Execute ───────────────────────────────────────────────────────────────────
;; Honor one parked action under the host lock: FLUSH/NEED_GIFT_ID run here;
;; dial / close / settle / fail park as post-lock fires. Returns updated
;; `(values touched fires)`. Kind inventory is generated
;; `host-dispatch-action!` — a new kind fails loud there. Each handler
;; returns `(values touched fires)` so the fold stays values-shaped (no box).
(define (apply-parked-action! m a touched fires)
  (host-dispatch-action!
   a
   (hash
    'flush
    (lambda (act)
      (define c (host-session-for-ptr m (cadr act)))
      (cond
        [c
         ;; The drain runs with breaks off, so a break can only land at its
         ;; edges, where it is the operator's interrupt and escapes as itself.
         (define failure
           (with-handlers ([(lambda (raised) (not (exn:break? raised))) values])
             (drain-outbound! c)
             #f))
         (when failure (record-session-outbound-failure! c failure))
         (values (if (memq c touched) touched (cons c touched))
                 (if failure
                     (cons (lambda () (retire-session-wire-failure! c)) fires)
                     fires))]
        [else (values touched fires)]))
    'close
    (lambda (act)
      ;; The host condemned the connection mid-pump (local turn budget
      ;; exceeded): drain its queued resource_exhausted abort so the
      ;; post-lock write carries it, then close the transport and release
      ;; the shell — deferred to the fires, which run after the touched
      ;; writes, once the host lock is released.
      (define c (host-session-for-ptr m (cadr act)))
      (cond
        [c
         ;; The drain runs with breaks off, so a break can only land at its
         ;; edges, where it is the operator's interrupt and escapes as itself.
         (define failure
           (with-handlers ([(lambda (raised) (not (exn:break? raised))) values])
             (drain-outbound! c)
             #f))
         (when failure (record-session-outbound-failure! c failure))
         (values (if (memq c touched) touched (cons c touched))
                 (cons (lambda () (finish-session-close! c (caddr act))) fires))]
        [else (values touched fires)]))
    'dial
    (lambda (act)
      ;; A dial is a connect syscall plus a whole keyed handshake:
      ;; post-lock, like every write and fire, or one slow exporter
      ;; parks every thread sharing the host. run-dial! borrows the exact
      ;; pending route for this attempt.
      (define ticket (cadr act))
      (define route-index (caddr act))
      (define attempt (cons ticket route-index))
      (define cancelled? (box #f))
      (define start (make-semaphore 0))
      (define worker
        (thread
         (lambda ()
           (without-deferred-drain-effects
            (lambda ()
              (sync start)
              (dynamic-wind
               void
               (lambda () (run-dial! m ticket route-index (lambda () (unbox cancelled?))))
               (lambda ()
                 (call-with-host/allow-released
                  m
                  (lambda () (hash-remove! (host-dial-workers m) attempt))))))))))
      (hash-set! (host-dial-workers m) attempt (dial-worker worker cancelled?))
      (values touched (cons (lambda () (semaphore-post start)) fires)))
    'cancel-dial
    (lambda (act)
      (define ticket (cadr act))
      (define route-index (caddr act))
      (define attempt (cons ticket route-index))
      (define worker (hash-ref (host-dial-workers m) attempt #f))
      (values
       touched
       (cons
        (lambda ()
          (when worker
            (set-box! (dial-worker-cancelled? worker) #t)
            (kill-thread (dial-worker-thread worker))
            (thread-wait (dial-worker-thread worker))
            (call-with-host/allow-released
             m
             (lambda () (hash-remove! (host-dial-workers m) attempt))))
          (call-with-host
           m
           (lambda ()
             (check/host (glowcap_host_dial_cancelled (host-ptr m) ticket route-index)))))
        fires)))
    'need-gift-id
    (lambda (act)
      (host-provide-gift-id! m (cadr act))
      (values touched fires))
    'settle
    (lambda (act)
      (values touched (append (reverse (settle-vow! m (cadr act) (cons 'ok (caddr act)))) fires)))
    'fail
    (lambda (act)
      (define outcome (vow-failure-outcome (caddr act) (cadddr act)))
      (values touched (append (reverse (settle-vow! m (cadr act) outcome)) fires)))
    'resume
    (lambda (_act)
      ;; The shared C pump reports this separately before dispatch; retain the
      ;; exhaustive generated handler for direct decoded-action callers.
      (values touched fires)))))

;; The one loop rule's drain: park via the shared C wrapper until dry, honoring
;; each arm, and return the `drain-effects` — parked writes and listener fires
;; — the caller runs with `run-drain-effects!` once the host lock is released.
;; The host lock is held. A NEED_GIFT_ID's provide may queue FLUSH legs, so we
;; re-park until the queue is empty (same as the pre-wrapper pull loop). FLUSH
;; order is action order, which is how the gifter's deposit leaves on the
;; exporter session before the give leaves on the serving one (the host queues
;; them exporter-first); the per-session FIFO preserves that order across
;; threads. SETTLE/FAIL route each vow's outcome to the `session-vow`
;; awaiting that id — registered at mint under this same lock, so the
;; completion always finds its box.
(define (drain-host-actions! m)
  ;; A loop-adopted host (ADR-0112) has no byte-fed pump: the loop executes
  ;; transport-shaped actions inside `glowcap_driver_step` and forwards the
  ;; application-visible ones as events, so the drain is one bracketed step
  ;; plus the event dispatch, and `glowcap_host_pump_drain` never runs
  ;; beside it.
  (define lp (host-loop-of m))
  (if lp
      ((unbox loop-drain-hook) m lp)
      (drain-pump-actions! m)))

(define (drain-pump-actions! m)
  (let loop ([touched '()] [fires '()] [popped? #f])
    ;; The native drain resumes queued Host work before its first external
    ;; action and may synchronously invoke a behavior.
    (define-values (parked yielded?)
      (parameterize ([current-deliver-owner m])
        (park-host-actions! m)))
    (define any-popped? (or popped? (pair? parked)))
    (define-values (t f)
      (for/fold ([touched touched] [fires fires]) ([a (in-list parked)])
        (apply-parked-action! m a touched fires)))
    (cond
      [yielded?
       ;; The continuation reacquires the host lock only after the current
       ;; effects have run and the Racket scheduler has received a turn.
       (drain-effects
        (reverse t)
        (reverse f)
        (lambda ()
          (call-with-host*
           m
           (lambda () no-drain-effects)
           (lambda () (drain-host-actions! m))))
        any-popped?)]
      [(null? parked) (drain-effects (reverse t) (reverse f) #f any-popped?)]
      [else
       (loop t f any-popped?)])))

;; Drive a byte-fed Host close without choosing any lifecycle transition here:
;; the core emits every effect, this loop executes it, supplies monotonic time,
;; and observes the terminal barrier. The wait is event-driven: snapshot the
;; host progress event before the progress check (the pump-until idiom, so a
;; verb landing between the check and the wait still wakes this loop), then
;; park on that snapshot or on the nearest FINISH grace deadline from
;; `glowcap_host_close_wait_ms`. A wait of -1 means no finite deadline is
;; pending: only host activity (a feed, a drain, a settle, an escalation)
;; can advance terminal progress, so the loop parks on activity alone.
(define (drive-host-close! m)
  (let loop ()
    (define gen (host-progress-evt m))
    (define state #f)
    (define close-code OK)
    (define wait-ms -1)
    (define fx
      (call-with-host
       m
       (lambda ()
         (define-values (rc lifecycle)
           (glowcap_host_close_progress (host-ptr m) (monotonic-ms)))
         (unless (or (= rc OK) (= rc ERR-TIMEOUT)) (check/host rc))
         (set! close-code rc)
         (set! state lifecycle)
         ;; Drain what progress queued before parking; a productive drain
         ;; bumps below, forcing one more progress check instead of parking
         ;; over undrained work.
         (define effects (drain-host-actions! m))
         (unless (lifecycle-closed? lifecycle)
           (define-values (wrc w)
             (glowcap_host_close_wait_ms (host-ptr m) (monotonic-ms)))
           (check/host wrc)
           (set! wait-ms w))
         effects)))
    (run-drain-effects! m fx)
    (when (drain-effects-productive? fx) (host-bump-progress! m))
    (cond
      [(lifecycle-closed? state) close-code]
      [(>= wait-ms 0) (sync/timeout (/ wait-ms 1000.0) gen) (loop)]
      [else (sync gen) (loop)])))

(set-box! host-close-barrier-hook drive-host-close!)
