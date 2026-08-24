#lang racket/base
;; Internal: distributed GC (ADR-0063), opt-in and off by default. Owns
;; `session-with-gc!` / recursive value tracking / `drain-gc!`, the weak per-Host
;; state table, the finalizer park, and the Host release verbs for references
;; and vows. Session keeps CapTP verbs that call these.

(require ffi/unsafe
         racket/async-channel
         "constants.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "value.rkt"
         "vat.rkt"
         "host/state.rkt"
         "action.rkt"
         "pump.rkt"
         "session/state.rkt")

;; Session state supplies `session-host`; pump owns the shared drain helpers.

(provide session-with-gc!
         session-gc-enabled?
         session-release!
         track-ref!
         track-vow!
         park-vow-release!
         track-argument!
         track-arguments!
         drain-gc!
         drain-host-gc!
         host-gc-pending?)

;; A Host with an opted-in connection carries a gc-state in this weak table.
;; A projected ref may be homed on a sibling session and outlive the session
;; through which it arrived, so the finalizer channel follows Host authority.
(define gc-states (make-weak-hasheq))
;; Opt-in remains per session even though the resulting finalizer state is Host-owned.
(define gc-enabled-connections (make-weak-hasheq))
;; Finalizer disarm tickets are binding state, not part of capability equality.
(define ref-gc-tokens (make-weak-hasheq))

;; The Host-wide GC state: finalizers park ids on `channel`; a Host-owner
;; thread transfers them to `pending` and performs native release. `gate`
;; makes enqueue and terminal retirement one transition, so no token can land
;; after its native owner has been consumed.
(struct gc-state (channel pending scheduled retired? gate))

(define (make-gc-state)
  (gc-state (make-async-channel) (box '()) (box #f) (box #f) (make-semaphore 1)))

(define (host-gc-state m)
  (hash-ref! gc-states m make-gc-state))

;; Finalizers only enqueue and wake the Host owner. The progress bump happens
;; after releasing `gate`, so Host retirement can never deadlock against a
;; finalizer waiting for the Host lock.
(define (queue-release! weak-host gs release)
  (define accepted?
    (call-with-semaphore
     (gc-state-gate gs)
     (lambda ()
       (cond
         [(unbox (gc-state-retired? gs)) #f]
         [else
          (async-channel-put (gc-state-channel gs) release)
          (set-box! (gc-state-scheduled gs) #t)
          #t]))))
  (when accepted?
    (define m (weak-box-value weak-host))
    (when m (host-bump-progress! m)))
  accepted?)

(define (retire-host-gc! m)
  (define gs (hash-ref gc-states m #f))
  (when gs
    (call-with-semaphore
     (gc-state-gate gs)
     (lambda ()
       (set-box! (gc-state-retired? gs) #t)
       (set-box! (gc-state-pending gs) '())
       (set-box! (gc-state-scheduled gs) #f)
       (let drain ()
         (when (async-channel-try-get (gc-state-channel gs)) (drain)))))
    (hash-remove! gc-states m)))

;; Opt this session into distributed GC (ADR-0063), off by default. Once on,
;; every capability occurrence projected through fetch, a fulfilled far
;; operation, or a delivered argument releases its Host retain when Racket's
;; collector reclaims it, so the partner can release the matching export.
;; Collection follows the collector's schedule; once parked, every release
;; remains owned until native commit. Locally minted capabilities and
;; `session-enliven` results owned by its dedup cache remain outside this seam.
;; Returns the session for chaining.
(define (session-with-gc! c)
  (hash-set! gc-enabled-connections c #t)
  (host-gc-state (session-host c))
  c)

;; Snapshot this session's opt-in when an application-facing vow is minted.
;; The vow row carries the decision through settlement; it must not infer GC
;; merely from having a home session, because enliven's dedup cache owns its
;; returned capability instead.
(define (session-gc-enabled? c)
  (and c (hash-ref gc-enabled-connections c #f) #t))

;; Register one projected capability occurrence when GC is on. The finalizer captures
;; only the integer Host id, never the `ref`, so it cannot resurrect
;; the handle whose death it waits on.
(define (track-ref! c capability)
  (define gs (hash-ref gc-states (session-host c) #f))
  (when (and (hash-ref gc-enabled-connections c #f) gs (ref? capability))
    (define id (ref-id capability))
    (define prior (hash-ref ref-gc-tokens capability #f))
    (when prior (set-box! prior #f))
    (define armed (box #t))
    (define weak-host (make-weak-box (session-host c)))
    (hash-set! ref-gc-tokens capability armed)
    (register-finalizer capability
                        (lambda (_)
                          (when (unbox armed)
                            (queue-release! weak-host gs (cons 'ref id))))))
  capability)

;; Every public far-vow handle owns one native Host vow independently of the
;; opt-in capability GC policy. Its finalizer parks only the id; the Host loop
;; performs the release and publishes op:gc-answer.
(define (queue-vow-release! weak-host gs id armed)
  (when (and armed (unbox armed))
    (set-box! armed #f)
    (queue-release! weak-host gs (cons 'vow id))))

(define (park-vow-release! m id armed)
  (queue-vow-release! (make-weak-box m) (host-gc-state m) id armed))

(define (track-vow! m vow id armed)
  (define weak-host (make-weak-box m))
  (define gs (host-gc-state m))
  (register-finalizer vow
                      (lambda (_)
                        (queue-vow-release! weak-host gs id armed))))

;; Attach one finalizer unit to every capability occurrence in a value the
;; native Host has just projected. Container identity stays unchanged; equal
;; ids in separate leaves intentionally receive separate death rites because
;; the native projection minted one Host retain per occurrence.
(define (track-argument! c value)
  (cond
    [(ref? value) (track-ref! c value)]
    [(list? value) (for-each (lambda (item) (track-argument! c item)) value)]
    [(pset? value) (for-each (lambda (item) (track-argument! c item)) (pset-items value))]
    [(tagged-arg? value)
     (for-each (lambda (item) (track-argument! c item)) (tagged-arg-value value))]
    [(struct-arg? value)
     (for-each (lambda (entry) (track-argument! c (cdr entry)))
               (struct-arg-entries value))]
    [else (void)])
  value)

(define (track-arguments! c values)
  (for-each (lambda (value) (track-argument! c value)) values)
  values)

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

;; Release the Host-owned FIFO prefix. The pending box advances only after one
;; native release commits, so a refusal preserves the exact token and tail in
;; front of capabilities collected concurrently.
(define (release-pending! pending release-one)
  (let loop ()
    (define remaining (unbox pending))
    (unless (null? remaining)
      (release-one (car remaining))
      (set-box! pending (cdr remaining))
      (loop))))

;; Whether a Host owner must make another GC drain pass. The driver loop checks
;; this after snapshotting Host progress, so an enqueue immediately before the
;; wait cannot be lost.
(define (host-gc-pending? m)
  (define gs (hash-ref gc-states m #f))
  (and gs
       (call-with-semaphore
        (gc-state-gate gs)
        (lambda ()
          (and (not (unbox (gc-state-retired? gs)))
               (or (unbox (gc-state-scheduled gs))
                   (pair? (unbox (gc-state-pending gs)))))))
       #t))

;; Move every async-channel token into the Host-owned FIFO. Clearing
;; `scheduled` between drains and then rechecking the channel closes the one
;; race where a finalizer enqueues while the old generation is still marked.
(define (collect-queued! gs)
  (call-with-semaphore
   (gc-state-gate gs)
   (lambda ()
     (unless (unbox (gc-state-retired? gs))
       (define ch (gc-state-channel gs))
       (define newly-collected
         (let loop ([acc '()])
           (define release (async-channel-try-get ch))
           (if release (loop (cons release acc)) (reverse acc))))
       (unless (null? newly-collected)
         (define pending (gc-state-pending gs))
         (set-box! pending (append (unbox pending) newly-collected)))
       (set-box! (gc-state-scheduled gs) #f)))))

;; Drain the parked GC releases on the calling Host-owner thread: one release
;; delta per reclaimed token, then flush. Called at every session verb head, so
;; a sibling can drain a release after the arrival session has closed.
(define (drain-host-gc! m)
  (define gs (hash-ref gc-states m #f))
  (when (and gs (host-gc-pending? m))
    (with-host-drain m
      (lambda ()
        (define pending (gc-state-pending gs))
        (collect-queued! gs)
        (cond
          [(unbox (host-released? m))
           ;; Host teardown already retired every retain; settle the surviving
           ;; binding queue as a successful no-op.
           (set-box! pending '())
           no-drain-effects]
          [(null? (unbox pending)) no-drain-effects]
          [else
           (release-pending!
            pending
            (lambda (release)
              (case (car release)
                [(ref)
                 (check/host
                  (pancake_host_ref_release
                   (host-ptr m) (make-PancakeReference (cdr release)) 1))]
                [(vow)
                 (hash-remove! (host-vows m) (cdr release))
                 (check/host (pancake_host_vow_release (host-ptr m) (cdr release)))]
                [else (error 'drain-host-gc! "unknown release kind: ~a" (car release))])))
           (drain-host-actions! m)]))
      #:allow-released? #t)))

(define (drain-gc! c)
  (drain-host-gc! (session-host c)))

(set-box! host-gc-retire-hook retire-host-gc!)

(module+ test
  (require rackunit)
  (define pending (box '((ref . 11) (ref . 12) (ref . 13))))
  (define refusal (exn:fail "release refused" (current-continuation-marks)))
  (define attempted '())
  (check-exn
   (lambda (raised) (eq? raised refusal))
   (lambda ()
     (release-pending!
      pending
      (lambda (release)
        (set! attempted (cons release attempted))
        (when (= (cdr release) 12) (raise refusal))))))
  (check-equal? (reverse attempted) '((ref . 11) (ref . 12)))
  (check-equal? (unbox pending) '((ref . 12) (ref . 13)))

  (define retired (make-gc-state))
  (set-box! (gc-state-retired? retired) #t)
  (check-false
   (queue-release! (make-weak-box #f) retired (cons 'ref 21)))
  (check-false (async-channel-try-get (gc-state-channel retired))))
