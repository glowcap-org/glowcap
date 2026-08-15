#lang racket/base
;; Internal: distributed GC (ADR-0063), opt-in and off by default. Owns
;; `session-with-gc!` / `track-import!` / `drain-gc!`, the weak per-Host
;; state table, the finalizer park, and `pancake_host_ref_release`. Session
;; keeps CapTP verbs that call these. Binding spine Pass 3b.

(require ffi/unsafe
         racket/async-channel
         racket/lazy-require
         "constants.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "value.rkt"
         "vat.rkt"
         "host.rkt"
         "action.rkt"
         "pump.rkt")

;; `session-host` / drain helpers live in session.rkt — lazy-require breaks
;; the session ↔ gc cycle (session eagerly requires this module).
(lazy-require
 ["session.rkt"
  (session-host
   session-ptr
   with-host-drain)])

(provide session-with-gc!
         session-release!
         track-import!
         drain-gc!
         drain-host-gc!)

;; A Host with an opted-in connection carries a gc-state in this weak table.
;; A fetched ref may be homed on a sibling session and outlive the session
;; through which it arrived, so the finalizer channel follows Host authority.
(define gc-states (make-weak-hasheq))
;; Opt-in remains per session even though the resulting finalizer state is Host-owned.
(define gc-enabled-connections (make-weak-hasheq))
;; Finalizer disarm tickets are binding state, not part of capability equality.
(define ref-gc-tokens (make-weak-hasheq))

;; The Host-wide GC state: an async-channel onto which a fetched
;; capability's finalizer (run on Racket's finalizer thread) parks its id.
;; Any sibling connection's verbs drain it on a pumping thread, where the host FFI
;; is safe to touch, and release one delta per parked token through
;; `pancake_host_ref_release` — never from the finalizer thread.
(struct gc-state (channel scheduled failure))

(define (retain-gc-failure! gs failure)
  (when (null? (unbox (gc-state-failure gs)))
    (set-box! (gc-state-failure gs) (list failure))))

;; Coalesce a collection storm to one worker per Host. The finalizer only
;; enqueues and schedules; the worker owns Host FFI and closes the enqueue-vs-
;; exit race before retiring itself.
(define (schedule-host-gc! weak-host gs)
  (when (box-cas! (gc-state-scheduled gs) #f #t)
    (thread
     (lambda ()
       (let loop ()
         (define m (weak-box-value weak-host))
         (when m
           (with-handlers ([(lambda (_) #t)
                            (lambda (failure) (retain-gc-failure! gs failure))])
             (drain-host-gc! m)))
         (set-box! (gc-state-scheduled gs) #f)
         (let ([pending (async-channel-try-get (gc-state-channel gs))])
           (when pending
             (async-channel-put (gc-state-channel gs) pending)
             (when (box-cas! (gc-state-scheduled gs) #f #t) (loop)))))))))

;; Opt this session into distributed GC (ADR-0063), off by default. Once on,
;; a capability returned by `session-fetch` releases its Host retain
;; when Racket's collector reclaims the last reference to it, so the partner can
;; release the matching export. Collection follows the collector's schedule;
;; once parked, every release remains owned until native commit. Capabilities
;; lifted elsewhere (a `session-send` reply, a delivered
;; argument, a `session-enliven` result the dedup cache owns) are outside this
;; seam. Returns the session for chaining.
(define (session-with-gc! c)
  (hash-set! gc-enabled-connections c #t)
  (hash-ref! gc-states (session-host c)
             (lambda () (gc-state (make-async-channel) (box #f) (box '()))))
  ;; Force the lazy `with-host-drain` stub now, on this user thread: the GC
  ;; worker is spawned from the FFI finalizer thread, where module paths do
  ;; not resolve (parameterization capture does not carry the expander's
  ;; resolver there), so a stub first forced on the worker dies unresolved.
  (with-host-drain (session-host c) (lambda () no-drain-effects))
  c)

;; Register a fetched capability for GC when GC is on. The finalizer captures
;; only the integer Host id, never the `ref`, so it cannot resurrect
;; the handle whose death it waits on.
(define (track-import! c capability)
  (define gs (hash-ref gc-states (session-host c) #f))
  (when (and (hash-ref gc-enabled-connections c #f) gs (ref? capability))
    (define id (ref-id capability))
    (define ch (gc-state-channel gs))
    (define prior (hash-ref ref-gc-tokens capability #f))
    (when prior (set-box! prior #f))
    (define armed (box #t))
    (define weak-host (make-weak-box (session-host c)))
    (hash-set! ref-gc-tokens capability armed)
    (register-finalizer capability
                        (lambda (_)
                          (when (unbox armed)
                            (async-channel-put ch id)
                            ;; Never call Host FFI on the finalizer thread.
                            ;; One coalesced worker drains the Host-owned queue;
                            ;; the weak box lets an already-dead Host stay dead.
                            (schedule-host-gc! weak-host gs)))))
  capability)

;; Give a capability back to the partner, now, because this application is
;; done holding it. The Host owns whether that retain corresponds to a local
;; object, a remote import, or a routed handoff. `capability` is spent afterwards.
(define (session-release! c capability)
  (unless (ref? capability)
    (error 'session-release! "takes a capability reference"))
  (when (ref-released? capability)
    (error 'session-release! "capability already released"))
  (define m (session-host c))
  (with-host-drain m
    (lambda ()
      (check/host (pancake_host_ref_release
                   (host-ptr m) (make-PancakeReference (ref-id capability)) 1))
      (drain-host-actions! m)))
  (define token (hash-ref ref-gc-tokens capability #f))
  (when token (set-box! token #f))
  (set-ref-released?! capability #t)
  (void))

;; Release a drained FIFO prefix. On refusal, the uncommitted token and tail go
;; back to the Host queue before the exact cause escapes.
(define (release-drained! ch drained release-one)
  (let loop ([remaining drained])
    (unless (null? remaining)
      (with-handlers ([(lambda (_) #t)
                       (lambda (failure)
                         (for ([id (in-list remaining)]) (async-channel-put ch id))
                         (raise failure))])
        (release-one (car remaining)))
      (loop (cdr remaining)))))

;; Drain the parked GC releases on the calling (pumping) thread: one release
;; delta per reclaimed token, then flush. Called at every session verb head, so
;; a sibling can drain a release after the arrival session has closed. A worker
;; failure has no caller, so the next verb receives its retained exact cause.
(define (drain-host-gc! m)
  (define gs (hash-ref gc-states m #f))
  (when gs
    (define retained (unbox (gc-state-failure gs)))
    (unless (null? retained)
      (set-box! (gc-state-failure gs) '())
      (raise (car retained)))
    (define ch (gc-state-channel gs))
    (define drained
      (let loop ([acc '()])
        (define id (sync/timeout 0 ch))
        (if id (loop (cons id acc)) (reverse acc))))
    (unless (null? drained)
      (with-host-drain m
        (lambda ()
          (cond
            [(unbox (host-released? m)) no-drain-effects]
            [else
             (release-drained!
              ch drained
              (lambda (id)
                (check/host
                 (pancake_host_ref_release (host-ptr m) (make-PancakeReference id) 1))))
             (drain-host-actions! m)]))
        #:allow-released? #t))))

(define (drain-gc! c)
  (drain-host-gc! (session-host c)))

(module+ test
  (require rackunit)
  (define ch (make-async-channel))
  (define refusal (exn:fail "release refused" (current-continuation-marks)))
  (define attempted '())
  (check-exn
   (lambda (raised) (eq? raised refusal))
   (lambda ()
     (release-drained!
      ch '(11 12 13)
      (lambda (id)
        (set! attempted (cons id attempted))
        (when (= id 12) (raise refusal))))))
  (check-equal? (reverse attempted) '(11 12))
  (check-equal? (async-channel-get ch) 12)
  (check-equal? (async-channel-get ch) 13))
