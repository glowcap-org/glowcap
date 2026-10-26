#lang racket/base
;; Internal: the CapTP `host`, the binding wrapper for `GlowcapHost` /
;; `driver_core.Host` (ADR-0022 / ADR-0011). The host owns an `engine.Node`
;; (the sans-io handoff router). Goblins `mycapn` is two roles, not one type:
;; the product maps to this Host; the router tables map to `engine.Node`. What lives
;; here is only what the embedder contract leaves to the binding: FFI Host
;; construction and release, profile and close-option projection, gift-id
;; entropy, C-facing Host verbs, and publication. The Racket-owned handle
;; state, reentrant lock, diagnostics, registries, loop hooks, and iroh redeem
;; posture live in `private/host/state.rkt`. Action decode +
;; execute (`drain-host-actions!` via `glowcap_host_pump_drain`) live in
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

;; Every session's maximum admissible frame; mirrors GLOWCAP_DEFAULT_FRAME_CAP.
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
       (raise-glowcap who ERR-INVALID-ARGUMENT
                      (format "#:grace-ms must be #f or an integer from 0 through ~a"
                              CLOSE-MAX-GRACE-MS))]))
  (make-GlowcapCloseOptions CLOSE-OPTIONS-ABI-VERSION
                            (ctype-sizeof _GlowcapCloseOptions)
                            pending-id
                            grace-mode
                            grace-value))

;; `#:profile` selects the core-authored `glowcap` or `interop` codec/version
;; pair. The individual `#:codec` and `#:captp-version` knobs remain available
;; when no profile is named; `#:features` completes this host's signed offer.
;; Each session settles version and codec with its partner,
;; falling back to v1.0/Syrup when needed, and runs only the intersection of the
;; two offered feature sets. Omitted `#:features` selects the generated default
;; offer; experimental multi-location routing requires explicit opt-in.
;; The host remembers the symbols so
;; `connect` can refuse explicit profile options that conflict with a shared
;; host's.
(define (make-host seed #:profile [profile #f]
                   #:codec [codec #f]
                   #:captp-version [captp-version #f]
                   #:features [features DEFAULT-FEATURES-SYMBOL]
                   #:local-turn-budget [local-turn-budget 0])
  (unless (and (bytes? seed) (= (bytes-length seed) 32))
    (raise-glowcap 'make-host ERR-INVALID-ARGUMENT "seed must be 32 bytes"))
  (define-values (selected-codec selected-captp-version)
    (host-profile-values 'make-host profile codec captp-version))
  ;; Keep an owned copy so caller mutation cannot split the FFI identity from
  ;; the seed used to derive the host's designator. status-allow: purpose clause
  (define durable-seed (bytes->immutable-bytes (bytes-copy seed)))
  ;; The durable identity followed by a session-key root drawn here, at this
  ;; binding's entropy boundary, because the library draws none (ADR-0028).
  ;; The root is fresh per process, so every CapTP session signs with its own
  ;; key and a restart cannot recreate a prior session's handoff names; the
  ;; durable half stays exactly `seed`, since a keyed locator's designator
  ;; derives from it.
  (define seed+root (bytes-append durable-seed (crypto-random-bytes 32)))
  (define sbuf (pin-immobile seed+root)) ; pin: the GC may move it mid-call
  (define-values (context-rc context) (glowcap_context_new))
  (check context-rc)
  (define-values (rc ptr)
    (glowcap_host_new_in context sbuf 64 HOST-FRAME-CAP 1 (codec-id selected-codec)
                        (captp-version-id selected-captp-version) (feature-mask features)
                        local-turn-budget 0))
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (glowcap_context_release context)
                     (raise error))])
    (check/host rc))
  (define-values (identity-rc diagnostic-id) (glowcap_host_diagnostic_id ptr))
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (define cleanup-code (glowcap_host_release ptr))
                     (define cleanup
                       (with-handlers ([(lambda (_) #t) values])
                         (check/host cleanup-code)
                         #f))
                     ;; A pre-commit refusal leaves an FFI Host borrowing
                     ;; this Context. Leak the pair rather than free its
                     ;; allocator policy under the still-live Host.
                     (when (release-consumed? cleanup-code)
                       (glowcap_context_release context))
                     (raise (if cleanup
                                (retain-cleanup-failure error cleanup)
                                error)))])
    (check/host identity-rc))
  (define m (host ptr context diagnostic-id durable-seed (make-semaphore 1) (box #f) (make-hash) (box (make-semaphore 0))
                  (make-hasheq) (make-hash) (make-hash) (box IROH-REACH-REDEEM-DEFAULT) (box #f) (box #f) (box #f) selected-codec selected-captp-version features (box #f) (make-hash)))
  ;; The host's own key designator, the name a partner knows it by: the
  ;; live trace reports it as this host's endpoint so one peer stays one node
  ;; in a feed several producers share.
  (trace-attach-host!
   m host-install-trace! (designator-from-seed durable-seed)
   (lambda (operation error)
     (host-record-callerless-failure! m operation error)))
  (register-finalizer m host-finalize!)
  m)

;; A host with a fresh random identity seed. Entropy is drawn at the binding
;; boundary, never inside the sans-io host.
(define (make-fresh-host #:profile [profile #f]
                         #:codec [codec #f]
                         #:captp-version [captp-version #f]
                         #:features [features DEFAULT-FEATURES-SYMBOL]
                         #:local-turn-budget [local-turn-budget 0])
  (make-host (crypto-random-bytes 32) #:profile profile #:codec codec #:captp-version captp-version
             #:features features
             #:local-turn-budget local-turn-budget))

;; A close requested inside an FFI callback records policy in FFI state
;; immediately. This set retains only which Host needs its release executor
;; after the callback unwinds; it never mirrors or replays close policy.
(define host-release-pending (make-hasheq))

;; One shared completion barrier per Host release. Repeated explicit close
;; forwards its request to FFI state, then joins this barrier and observes
;; the same result as the executor.
(struct release-barrier (done result [worker #:mutable]) #:transparent)
(struct release-result (error) #:transparent)
(define host-release-active (make-hasheq))

(define (publish-host-release! m barrier outcome)
  ;; Once the FFI pointer moves, result publication and waiter wakeup are one
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
           ;; after the FFI barrier projected every terminal event.
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
                    ((unbox loop-ffi-release-hook) lp)
                    (let ([code (glowcap_host_release ptr)])
                      (values
                       code
                       (with-handlers ([(lambda (_) #t) values])
                         (check/host code)
                         #f)))))
              (when (release-consumed? release-code)
                (glowcap_context_release (host-context m))
                (trace-detach-host! m)
                ((unbox host-gc-retire-hook) m)
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
      (check/host (glowcap_host_close (host-ptr m) options (monotonic-ms)))))

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

;; driver loop retirement has already crossed its close barrier. Release the
;; loop/Host allocation without beginning a second policy request.
(define (host-release-after-ffi-close! m)
  (host-release/options! m #f #f))

;; A failed loop has already stopped ordinary stepping, so it cannot drive a
;; second FFI close policy. Install its memory-only release barrier before
;; returning to the failing park/retirement thread, but leave that thread free
;; to exit: the release worker joins it during `loop-prestop!`.
(define (host-release-after-ffi-close/async! m)
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
;; An unreachable Host has no reachable session wrapper; FFI release owns
;; the remaining physical cleanup.
(define (host-finalize! m)
  (run-ffi-finalizer!
   "host.finalizer.release"
   (lambda () (host-release/options! m #f #f))))

(define (host-release/options! m options close-sessions?)
  (define disposition
    (call-with-host/terminal
     m
     (lambda ()
       ;; No break may land between the FFI request and installing its one
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
           ;; FFI close records the admission barrier under the callback latch;
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
  ;; drain bumps when the turn unwinds; bumping earlier lets the turn's own status-allow: event or source ordering
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
;; reply becomes a gift. The host originates the claimed handoff and
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
     (check/host (glowcap_host_provide_gift_id (host-ptr m) ticket (pin-immobile id) 32)))
   (lambda ()
     (check/host (glowcap_host_gift_id_failed (host-ptr m) ticket)))))

(module+ test
  (require rackunit)
  (define-values (glowcap-codec glowcap-version)
    (host-profile-values 'test 'glowcap #f #f))
  (check-equal? glowcap-codec OWN-CODEC-SYMBOL)
  (check-equal? glowcap-version OWN-CAPTP-VERSION-SYMBOL)
  (define-values (interop-codec interop-version)
    (host-profile-values 'test 'interop #f #f))
  (check-equal? interop-codec INTEROP-CODEC-SYMBOL)
  (check-equal? interop-version INTEROP-CAPTP-VERSION-SYMBOL)
  (check-exn exn:fail:glowcap?
             (lambda () (host-profile-values 'test 'glowcap 'syrup #f)))
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
(define (host-dialed! m ticket route-index session-ptr)
  (define adopted (malloc _uint8 'atomic-interior))
  (ptr-set! adopted _uint8 0)
  (check/host (glowcap_host_dialed (host-ptr m) ticket route-index session-ptr adopted))
  (not (zero? (ptr-ref adopted _uint8))))

(define (host-dial-failed! m ticket route-index reason)
  (define bs (string->bytes/utf-8 reason))
  (check/host (glowcap_host_dial_failed (host-ptr m) ticket route-index (pin-immobile bs) (bytes-length bs))))

;; Retain and select this Host's complete acceptable location.
(define (host-set-advertised-locator! m loc)
  (call-with-locator-view
   loc
   (lambda (view)
     (call-with-host m
       (lambda ()
         (check/host (glowcap_host_set_advertised_locator (host-ptr m) view)))))))

(define (host-remove-advertised-locator! m transport)
  (define bs (string->bytes/utf-8 transport))
  (call-with-host m
    (lambda ()
      (check/host (glowcap_host_remove_advertised_locator
                   (host-ptr m) (pin-immobile bs) (bytes-length bs))))))

;; Selective limits copied into peers minted after this call. Zero leaves a
;; field unchanged; durable sent answers stay separate from transient flow,
;; and max-sessions is the Host-wide cap on live sessions.
(define (host-set-session-limits! m
                                  #:max-frame-bytes [max-frame-bytes 0]
                                  #:queue-cap [queue-cap 0]
                                  #:outbound-high-water-bytes [outbound-high-water-bytes 0]
                                  #:max-retained-sent-answer-bytes [max-retained-sent-answer-bytes 0]
                                  #:max-sessions [max-sessions 0])
  (define size-max (sub1 (expt 2 (* 8 (ctype-sizeof _size)))))
  (for ([name (in-list '(max-frame-bytes queue-cap outbound-high-water-bytes
                                      max-retained-sent-answer-bytes max-sessions))]
        [value (in-list (list max-frame-bytes queue-cap outbound-high-water-bytes
                              max-retained-sent-answer-bytes max-sessions))])
    (unless (and (exact-nonnegative-integer? value) (<= value size-max))
      (raise-glowcap 'host-set-session-limits! ERR-INVALID-ARGUMENT
                     (format "#:~a exceeds this target's supported range" name))))
  (when (> max-retained-sent-answer-bytes #xffffffff)
    (raise-glowcap 'host-set-session-limits! ERR-INVALID-ARGUMENT
                   "#:max-retained-sent-answer-bytes exceeds uint32 capacity"))
  (define options
    (make-GlowcapSessionLimitOptions
     SESSION-LIMIT-OPTIONS-ABI-VERSION
     (ctype-sizeof _GlowcapSessionLimitOptions)
     max-frame-bytes queue-cap outbound-high-water-bytes
     max-retained-sent-answer-bytes max-sessions))
  (call-with-host m
    (lambda ()
      (check/host (glowcap_host_set_session_limits (host-ptr m) options)))))

;; Bootstrap queue bounds include message spines and rows, with no eager backing.
(define (host-set-ingress-limits! m #:max-pending-turns turns
                                  #:max-pending-bytes bytes #:max-chunk-bytes chunk)
  (for ([value (in-list (list turns bytes chunk))])
    (unless (and (exact-positive-integer? value) (<= value #xffffffff))
      (raise-glowcap 'host-set-ingress-limits! ERR-INVALID-ARGUMENT
                     "ingress limits must be positive uint32 integers")))
  (call-with-host m
    (lambda ()
      (check/host (glowcap_host_set_ingress_limits (host-ptr m) turns bytes chunk)))))

;; Derive the canonical key designator (64 lowercase hex digits) from a 32-byte
;; Ed25519 identity seed (the public half of the key a host signs with,
;; ADR-0028).
(define (designator-from-seed seed)
  (unless (= (bytes-length seed) 32)
    (raise-glowcap 'designator-from-seed ERR-INVALID-ARGUMENT
                   "seed must be 32 bytes"))
  ;; Output buffer is mutable Racket bytes the FFI writes into. Do not
  ;; `pin-immobile` it (that copies, and the write would be discarded). Plain
  ;; bytes are safe here only because this call is not marked `#:blocking?`, so
  ;; the collector cannot run and move the block under it; a blocking call needs
  ;; `out-immobile` instead.
  (define out (make-bytes 64))
  (check/host (glowcap_host_designator_from_seed (pin-immobile seed) 32 out 64))
  (bytes->string/utf-8 out))

;; ── Host-wide publications ───────────────────────────────────────────────────────
;; Host `behavior` once and bind `name` as a Host-wide alias. Fetch lazily
;; projects the actor onto a session; a deposited gift keeps that exact actor
;; when a recipient withdraws over its own exporter session. The binding keeps
;; the trampoline alive. The behavior is an ordinary actor behavior
;; `(lambda (method . args) …)`, e.g. one built with `methods`.
(define (host-publish m name behavior)
  (define tramp (make-publication-trampoline behavior))
  (host-retain! m tramp)
  (define nb (string->bytes/utf-8 name))
  ;; The host never owns the row (the free callback is #f), so a refused
  ;; publish must retire the retained closure or it leaks for the host's life.
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (host-retire! m tramp) (raise e))])
    (call-with-host m
      (lambda ()
        (check/host (glowcap_host_publish (host-ptr m) (pin-immobile nb) (bytes-length nb)
                                          tramp #f #f))))))

;; Remove the Host-wide alias `name` (alias-only): a later fetch misses on
;; every session, while issued refs and deposited gifts keep the exact actor,
;; whose retained trampoline stays hosted for the host's life. Returns #f when
;; no such alias exists.
(define (host-unpublish m name)
  (define nb (string->bytes/utf-8 name))
  (call-with-host m
    (lambda ()
      (define rc (glowcap_host_unpublish (host-ptr m) (pin-immobile nb) (bytes-length nb)))
      (cond
        [(= rc ERR-NOT-FOUND) #f]
        [else (check/host rc) #t]))))

;; Publish `behavior` under a freshly minted durable swiss name (ADR-0007) and
;; return that name (the swiss to place in a sturdyref beside this host's own
;; locator). The name is unpredictable, never reassigned, structurally disjoint
;; from every mutable alias, and removable only through `host-remove-durable`.
;; Optional `entropy` must be exactly HOST-DURABLE-ENTROPY-LEN bytes and
;; restores the same name on a Host reconstructed from the same seed; omitted,
;; this method draws it from the OS RNG.
(define (host-publish-durable m behavior [entropy #f])
  (define entropy-bytes
    (cond
      [(not entropy) (crypto-random-bytes HOST-DURABLE-ENTROPY-LEN)]
      [(and (bytes? entropy)
            (= (bytes-length entropy) HOST-DURABLE-ENTROPY-LEN))
       entropy]
      [else
       (raise-glowcap 'host-publish-durable ERR-INVALID-ARGUMENT
                      "durable entropy must be exactly ~a bytes"
                      HOST-DURABLE-ENTROPY-LEN)]))
  (define tramp (make-publication-trampoline behavior))
  (host-retain! m tramp)
  ;; Output buffer is mutable Racket bytes the FFI writes into. Do not
  ;; `pin-immobile` it (that copies, and the write would be discarded). Plain
  ;; bytes are safe here only because this call is not marked `#:blocking?`, so
  ;; the collector cannot run and move the block under it; a blocking call needs
  ;; `out-immobile` instead.
  (define out (make-bytes HOST-DURABLE-SWISS-LEN))
  ;; The host never owns the row (the free callback is #f), so a refused
  ;; publish must retire the retained closure or it leaks for the host's life.
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (host-retire! m tramp) (raise e))])
    (call-with-host m
      (lambda ()
        (define written
          (glowcap_host_publish_durable (host-ptr m)
                                        (pin-immobile entropy-bytes)
                                        (bytes-length entropy-bytes)
                                        tramp #f #f
                                        out (bytes-length out)))
        (when (<= written 0) (check/host written))
        (bytes->string/utf-8 (subbytes out 0 written))))))

;; Publish the exact held reference. The name retains an independent root;
;; after removal, the same entropy restores the name; live collisions refuse.
(define (host-publish-reference m reference [entropy #f])
  (define seed (or entropy (crypto-random-bytes HOST-DURABLE-ENTROPY-LEN)))
  (unless (and (bytes? seed) (= (bytes-length seed) HOST-DURABLE-ENTROPY-LEN))
    (raise-glowcap 'host-publish-reference ERR-INVALID-ARGUMENT "invalid durable entropy length"))
  (define out (make-bytes HOST-DURABLE-SWISS-LEN))
  (call-with-host m
    (lambda ()
      (define written
        (glowcap_host_publish_reference (host-ptr m) (ref->c reference)
                                       (pin-immobile seed) (bytes-length seed)
                                       out (bytes-length out)))
      (when (<= written 0) (check/host written))
      (unless (= written (bytes-length out))
        (raise-glowcap 'host-publish-reference ERR-INTERNAL "publication returned an invalid name length"))
      (bytes->string/utf-8 out))))

;; Remove a minted durable publication (ADR-0007): the old sturdyref misses status-allow: replacement state identity
;; from now on, while issued refs and deposited gifts keep the exact actor.
;; Returns #f when no such durable name exists.
(define (host-remove-durable m swiss)
  (define sb (string->bytes/utf-8 swiss))
  (call-with-host m
    (lambda ()
      (define rc (glowcap_host_remove_durable (host-ptr m) (pin-immobile sb) (bytes-length sb)))
      (cond
        [(= rc ERR-NOT-FOUND) #f]
        [else (check/host rc) #t]))))
