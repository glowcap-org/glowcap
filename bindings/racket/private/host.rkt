#lang racket/base
;; Internal: the CapTP `host` — binding wrapper for `PancakeHost` /
;; `driver_core.Host` (ADR-0072 / ADR-0079). The host owns an `engine.Node`
;; (the sans-io handoff router). Goblins `mycapn` is two roles, not one type:
;; the product maps to this Host; the router tables map to `engine.Node`. What lives
;; here is only what the embedder contract leaves to the binding: native Host
;; construction and release, profile and close-option projection, gift-id
;; entropy, C-facing Host verbs, and publication. The Racket-owned handle
;; state, reentrant lock, diagnostics, registries, loop hooks, and iroh redeem
;; posture live in `private/host/state.rkt`. Action decode +
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
         "host/state.rkt")

(provide (all-defined-out))

;; Every session's maximum admissible frame; mirrors PANCAKE_DEFAULT_FRAME_CAP.
(define HOST-FRAME-CAP DEFAULT-FRAME-CAP)

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

;; `#:codec`, `#:captp-version`, and `#:features` are this host's signed
;; profile offer. Each session settles version and codec with its partner,
;; falling back to v1.0/Syrup when needed, and runs only the intersection of the
;; two offered feature sets. Omitted `#:features` means the full feature set.
;; The host remembers the symbols so
;; `connect` can refuse explicit profile options that conflict with a shared
;; host's.
(define (make-host seed #:codec [codec DEFAULT-CODEC-SYMBOL]
                   #:captp-version [captp-version DEFAULT-CAPTP-VERSION-SYMBOL]
                   #:features [features DEFAULT-FEATURES-SYMBOL]
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
(define (make-fresh-host #:codec [codec DEFAULT-CODEC-SYMBOL]
                         #:captp-version [captp-version DEFAULT-CAPTP-VERSION-SYMBOL]
                         #:features [features DEFAULT-FEATURES-SYMBOL]
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

;; ── Host verbs the drain loop answers actions with ───────────────────────────
;; Decode and the drain switch (`drain-host-actions!`) live in
;; `private/action.rkt`. The verbs below are what those arms call.

;; Answer a NEED_GIFT_ID action: entropy is a host effect, drawn only when a
;; reply actually becomes a gift. The host originates the claimed handoff and
;; flushes its legs, exporter first. Caller holds the host lock.
(define (answer-gift-id! draw provide failed)
  (define id
    (with-handlers ([exn:fail? (lambda (_error) #f)])
      (draw)))
  (if id (provide id) (failed)))

(define (host-provide-gift-id! m ticket)
  (answer-gift-id!
   (lambda () (crypto-random-bytes 32))
   (lambda (id)
     (check/host (pancake_host_provide_gift_id (host-ptr m) ticket (pin-immobile id) 32)))
   (lambda ()
     (check/host (pancake_host_gift_id_failed (host-ptr m) ticket)))))

(module+ test
  (require rackunit)
  (define failed 0)
  (answer-gift-id!
   (lambda () (error 'entropy "unavailable"))
   (lambda (_id) (error 'test "entropy failure reached provide"))
   (lambda () (set! failed (add1 failed))))
  (check-equal? failed 1)
  (define refusal (exn:fail "ticket refused" (current-continuation-marks)))
  (check-exn
   (lambda (error) (eq? error refusal))
   (lambda ()
     (answer-gift-id!
      (lambda () (make-bytes 32))
      (lambda (_id) (raise refusal))
      (lambda () (set! failed (add1 failed))))))
  (check-equal? failed 1))

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
