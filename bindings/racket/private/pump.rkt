#lang racket/base
;; Internal: the byte-fed embedder pump choreography over the host
;; (libglowcap_host, ADR-0072 / ADR-0079).
;;
;; Owns the connection byte path the embedder contract leaves to the binding:
;; the keyed handshake, read raw bytes off the transport, hand them to the
;; core's stream delimiter (`glowcap_host_session_feed_bytes`, which owns framing),
;; write what `take_outbound` drains, the feed-refusal path (`last_abort` /
;; abort), and the EOF teardown that `transport_closed` reports to the core.
;; The CapTP surface stays in the `private/session` module family; the host
;; action switch (`drain-host-actions!`) lives in `private/action.rkt`. This
;; module is required by that family; the public barrel reaches pump only
;; through session verbs / dogfood plumbing.

(require ffi/unsafe
         racket/lazy-require
         racket/string
         "constants.rkt"
         "ffi-ocapn.rkt"
         "ffi-host.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "value.rkt"
         "async.rkt"
         "pending-writes.rkt"
         "host/state.rkt"
         "vat.rkt"
         "session/state.rkt")

;; `session/state.rkt` owns the `session` type; this module owns the shared
;; lock-drain choreography (`with-host-drain` / `drain-host!` / …), and action
;; owns the drain switch.
;; Lazy-require breaks the session ↔ pump, action ↔ pump, and gc ↔ pump cycles:
;; session and action eagerly require this module for the byte path / FLUSH arm.
(lazy-require
 ["session.rkt"
  (abandon-session!
   retire-session-wire-failure!)]
 ["action.rkt"
  (drain-host-actions!)]
 ["gc.rkt"
  (drain-host-gc!)]
 ["trampoline.rkt"
  (inside-turn?)])

(provide drain-effects
         drain-effects-touched
         drain-effects-fires
         drain-effects-resume
         drain-effects-popped?
         drain-effects?
         drain-effects-productive?
         no-drain-effects
         current-defer-drain-effects
         without-deferred-drain-effects
         with-host-drain
         with-session-drain
         drain-host!
         run-drain-effects!
         current-deliver-owner
         HANDSHAKE-TIMEOUT-MS
         drain-outbound!
         pending-writes-clear!
         write-pending!
         feed-bytes!
         capture-feed-refusal
         raise-feed-refusal
         handle-session-eof!
         pump-read-once!
         pump-until
         run-handshake!
         session-last-abort
         break-far-vows-bytes!
         transport-closed-bytes!)

;; The Session or Host whose native progress call is running. Hosted callbacks
;; fire synchronously inside that call; the turn itself then identifies the
;; exact ingress Session.
(define current-deliver-owner (make-parameter #f))

;; What one locked drain hands back to run once the host lock releases: the
;; connections whose outbound was drained, and the deferred fires — settled
;; vows' listeners, dial executors, condemned-connection closes. Everything
;; here must run post-lock: a socket write can block, a dial is a connect
;; syscall plus a whole keyed handshake, and a listener is application code
;; that may pump. When the feed runs under the reader gate,
;; `current-defer-drain-effects` parks this record until the gate releases —
;; writes and fires never share the reader window with a blocking TCP write.
(struct drain-effects (touched fires resume popped?))
(define no-drain-effects (drain-effects '() '() #f #f))

;; A drain pass advanced close-relevant state exactly when it popped at least
;; one action; `popped?` records that at the drain, because an action can
;; retire state (an unwrapped session's release, for one) while leaving no
;; touched session and no fire behind. The close drivers bump host progress
;; only for such a pass: an idle pass stays silent, which keeps two drivers
;; parked on the progress event from waking each other in an endless idle
;; exchange.
(define (drain-effects-productive? fx)
  (or (drain-effects-popped? fx)
      (pair? (drain-effects-touched fx))
      (pair? (drain-effects-fires fx))
      (and (drain-effects-resume fx) #t)))

;; When non-#f, a box of `drain-effects`. `with-host-drain` parks writes and
;; fires into it instead of running them, and does not bump progress — the
;; reader that set the parameter runs them after releasing the gate. Lives
;; here (not session) so `parameterize` sees a real parameter; lazy-require
;; would wrap it as a procedure.
(define current-defer-drain-effects (make-parameter #f))

;; Racket threads inherit parameter values. Workers whose lifetime escapes the
;; reader transaction must start with no inherited effects sink, or a later
;; host drain can append writes to a reader box that has already been consumed.
(define (without-deferred-drain-effects thunk)
  (parameterize ([current-defer-drain-effects #f])
    (thunk)))

;; Write every session a drain flushed, tolerating a dead transport per
;; session so one broken partner never strands another's frames.
(define (write-touched! touched)
  (for ([c (in-list touched)])
    (with-handlers
        ([(lambda (_e) #t)
          (lambda (error)
            ;; A popped frame cannot be replayed, and the stream may contain
            ;; only its prefix. End this session so its far vows settle closed;
            ;; keep draining unrelated sessions while the exact write error
            ;; remains observable on this Session.
            (record-session-outbound-failure! c error)
            (retire-session-wire-failure! c))])
      (write-pending! c))))

;; Run the post-lock half of a drain: write flushed connections, then fire
;; deferred dials / settles / closes.
(define (run-drain-effects! m fx)
  (let loop ([current fx])
    (write-touched! (drain-effects-touched current))
    (for ([fire (in-list (drain-effects-fires current))])
      (with-handlers ([converts-to-broken?
                       (lambda (error)
                         (record-host-runtime-failure! m error)
                         (void))])
        (fire)))
    (when (drain-effects-resume current)
      ;; A native yield is an explicit scheduler boundary. Run its continuation
      ;; in a nested Racket thread: the caller still joins the complete drain,
      ;; while progress no longer depends on an elapsed-time sleep or immediate
      ;; re-entry into the FFI callback's scheduler turn.
      (loop (call-in-nested-thread (drain-effects-resume current))))))

;; Merge two drain-effects records in FIFO order (earlier first). Used when a
;; reader-held feed nests further locked drains under the same deferral box.
(define (merge-drain-effects a b)
  (drain-effects
   (append (drain-effects-touched a) (drain-effects-touched b))
   (append (drain-effects-fires a) (drain-effects-fires b))
   (cond
     [(and (drain-effects-resume a) (drain-effects-resume b))
      (lambda ()
        (merge-drain-effects
         ((drain-effects-resume a))
         ((drain-effects-resume b))))]
     [(drain-effects-resume a)]
     [(drain-effects-resume b)]
     [else #f])
   (or (drain-effects-popped? a) (drain-effects-popped? b))))

;; The one drain choreography every host-driving path shares: run `thunk`
;; under the host lock — it returns the locked drain's `drain-effects` (most
;; sites end in `drain-host-actions!`; some substitute `no-drain-effects` or a
;; merged record) plus any extra values — then run those effects (socket
;; writes, listener fires) after the lock releases, wake every parked pump,
;; and hand the extra values back to the caller. Under
;; `current-defer-drain-effects`, only the merge happens here; the reader
;; after-thunk owns effects + bump.
(define (with-host-drain m thunk #:allow-released? [allow-released? #f])
  (call-with-values
   (lambda ()
     ((if allow-released? call-with-host/terminal call-with-host) m thunk))
   (lambda (fx . rest)
     (cond
       [(current-defer-drain-effects)
        => (lambda (box)
             (set-box! box (merge-drain-effects (unbox box) fx))
             (apply values rest))]
       [else
        ;; Guarantee the bump even if a break interrupts the effects: the
        ;; drain already committed the state a parked pump spins on (settles,
        ;; closes), so a skipped bump would strand that waiter. The post-thunk
        ;; fires it on a break escape too (same shape as the reader after-thunk
        ;; in `pump-until`); a spare bump is harmless.
        (dynamic-wind
         void
         (lambda () (run-drain-effects! m fx))
         (lambda () (host-bump-progress! m)))
        (apply values rest)]))))

;; The session-effect drain teardown paths share: unless `c` is already
;; released (its handle must see no further host verb), run `thunk` and drain
;; what it queued, all inside one `with-host-drain`.
(define (with-session-drain c thunk)
  (define m (session-host c))
  (with-host-drain m
    (lambda ()
      (cond
        [(session-released? c) no-drain-effects]
        [else
         (thunk)
         (drain-host-actions! m)]))))

;; Drain actions under the lock, write the flushed connections after it
;; releases, and wake every parked pump. A no-op inside a hosted turn: the
;; host refuses the driving verbs there, and everything the turn enqueued
;; flushes when the enclosing feed unwinds into this same drain.
(define (drain-host! m)
  (unless (inside-turn?)
    (host-drain-parked-releases! m)
    (drain-host-gc! m)
    (with-host-drain m (lambda () (drain-host-actions! m)))))

;; ── The bounded wait ──────────────────────────────────────────────────────────
;; How long a partner has to finish the keyed handshake once its byte channel
;; is open. The value itself is the C ABI's (`GLOWCAP_HANDSHAKE_TIMEOUT_MS`),
;; arriving through `constants.rkt`, so the four bindings promise one number
;; rather than four. Something finite is the point: an unbounded CapTP wait is
;; a hang rather than a slow success.

;; The absolute `current-inexact-milliseconds` a bounded pump must not outlive,
;; or #f for an unbounded one. A partner that connects and then says nothing
;; never fails, so no error path ends that wait — only a deadline does, and it
;; has to reach the blocked reader as an event, not a poll. `pump-wake-evt`
;; folds the deadline into the wake event every transport's `read-some!`
;; already waits on beside its own bytes, so a silent stream still wakes;
;; `pump-until` then raises. Same parameter-lives-in-pump rule as above.
(define current-pump-deadline (make-parameter #f))

;; `alarm-evt` stays ready once it fires, so a passed deadline costs at most
;; one extra loop before the raise rather than spinning.
(define (pump-wake-evt m)
  (define gen (host-progress-evt m))
  (define deadline (current-pump-deadline))
  (if deadline (choice-evt gen (alarm-evt deadline)) gen))

(define (pump-deadline-passed?)
  (define deadline (current-pump-deadline))
  (and deadline (>= (current-inexact-milliseconds) deadline) #t))

;; The typed cause of this CapTP session's most recent local dispatch failure, or
;; #f — the host counterpart of the Zig `Peer.lastAbort`, read through the
;; shared `GlowcapLastAbort` layout. Feed-refusal owns the reader; Session
;; re-exports the name for dogfood/plumbing.
(define (session-last-abort c)
  (call-with-host
   (session-host c)
   (lambda ()
     (guard-open 'session-last-abort c)
     (define out (make-GlowcapLastAbort 0 0 #f 0 #f 0 #f 0 #f 0 #f 0 0))
     (define rc (glowcap_host_session_last_abort (session-ptr c) out))
     (cond
       [(= rc WOULD-BLOCK) #f]
       [else (check/host rc) (abort-info<-c out)]))))

;; Host FFI for breaking far vows parked on `c`. Caller owns the
;; `with-session-drain` window so queued completions drain in order.
(define (break-far-vows-bytes! c bs)
  (check/host (glowcap_host_session_break_far_vows
               (session-ptr c) (pin-immobile bs) (bytes-length bs))))

;; Host FFI for reporting that `c` lost its transport. Caller owns the
;; `with-session-drain` window so terminal FAIL completions drain in order.
(define (transport-closed-bytes! c bs)
  (check/host (glowcap_host_session_transport_closed
               (session-ptr c) (pin-immobile bs) (bytes-length bs))))

;; Pop transport-ready prefix/payload vectors on `c` into its pending-writes
;; FIFO. The host returns canonical outer framing for clear sessions and an
;; empty prefix for wire-ready sealed payloads. Admission is checked before
;; `take_outbound` transfers ownership, so a full FIFO never drops an already
;; popped frame. One admitted frame may carry the FIFO over its high-water; the
;; drain then stops until `write-pending!` debits it. Caller holds the host lock
;; (`take_outbound` is a host verb); the socket write happens after the lock
;; releases, through `write-pending!`. Returns `empty` only when the core queue
;; was observed empty; every other result means the writer must refill after it
;; drains this bounded batch.
(define (drain-outbound! c)
  ;; A loop-owned host's wire belongs to the loop (ADR-0112): its steps
  ;; flush queued outbound themselves, and `take_outbound` must not compete
  ;; with them, so a loop-hosted session drains nothing here.
  (if (or (session-released? c) (host-loop-of (session-host c)))
      'empty
      (let loop ([queued? #f])
        (if (pending-writes-has-room? (session-pending-writes c))
            (let ([mf (session-outbound-frame c)]
                  [prefix (session-outbound-prefix c)])
              (define-values (rc prefix-len)
                (glowcap_host_session_take_outbound
                 (session-ptr c) mf prefix (bytes-length prefix)))
              (cond
                [(= rc WOULD-BLOCK) (if queued? 'queued-drained 'empty)]
                [else
                 (check/host rc)
                 (define out
                   (dynamic-wind
                    void
                    (lambda ()
                      (bytes<-c (GlowcapManagedFrame-bytes mf)
                                (GlowcapManagedFrame-len mf)))
                    (lambda () (glowcap_managed_frame_release mf))))
                 (if (pending-writes-put-pair!
                      (session-pending-writes c)
                      (subbytes prefix 0 prefix-len)
                      out)
                     (loop #t)
                     'queued-bounded)]))
            (if queued? 'queued-bounded 'bounded)))))

;; Write everything parked on `c`'s pending-writes FIFO to the transport,
;; flushing once, serialized by the connection's write gate. Runs outside the
;; host lock; a dead transport's write error is the caller's to tolerate.
;; Callers must not hold `c`'s reader gate: reader-held feeds park frames in
;; `drain-effects` via `current-defer-drain-effects`, and `pump-until` writes
;; only after the gate clears.
(define (write-pending! c)
  ;; The loop-owned early-out above holds here too: the loop writes its own
  ;; wire, and this session's FIFO stays empty.
  (unless (or (session-released? c) (host-loop-of (session-host c)))
    (define tr (async-connection-transport (session-async c)))
    (call-with-semaphore
     (session-write-gate c)
     (lambda ()
       (let batch-loop ()
         (define wrote?
           (let write-loop ([wrote? #f])
             (define out (pending-writes-try-get! (session-pending-writes c)))
             (if out
                 (begin
                   ((async-transport-write-frame! tr) out)
                   (write-loop #t))
                 wrote?)))
         (when wrote?
           ((async-transport-flush! tr)))
         ;; The binding FIFO is only a bounded staging batch. Refill it under
         ;; the host lock after the socket write, then release the lock before
         ;; writing that batch. `empty` is the sole proof that no core frame was
         ;; stranded behind the high-water stop.
         (unless (session-released? c)
           (define status
             (call-with-host (session-host c) (lambda () (drain-outbound! c))))
           (unless (eq? status 'empty) (batch-loop))))))))

;; Feed freshly read bytes into the host through the core's stream delimiter
;; (`glowcap_host_session_feed_bytes`): the session's codec splits each
;; complete frame off the front — both codecs, both frame shapes, the frame
;; cap enforced during the scan — and dispatches it (behavior and settle
;; callbacks fire inside), then the actions the dispatch queued drain. The
;; library owns the unconsumed tail — a partial frame straddling two reads
;; stays buffered in the session — so one call moves the whole read. The serve
;; loop resumes any handshake-held tail through `resume-feed!`. On a refused
;; stream the peer has already projected a typed op:abort; write it so the
;; partner hears why, then raise the typed failure carrying the
;; connection's `abort-info`. The FFI pin (`pin-immobile`) is a named Racket
;; collector cost on every feed.
(define (feed-bytes! c got)
  (define m (session-host c))
  (let loop ()
    ;; The refusal is captured under the lock: it parks the abort on the FIFO
    ;; and marks `c` touched so `run-drain-effects!` writes it — under the
    ;; reader that runs after the gate clears; outside the reader it runs
    ;; before this returns. Then raise.
    (define result
      (with-host-drain m
        (lambda ()
          ;; Release and feed serialize on this same host lock. The guard must
          ;; live here, not before lock acquisition, or close can free the
          ;; native handle while this thread is waiting to feed it.
          (guard-open 'session-serve c)
          (define buf (pin-immobile got))
          (define rc
            (parameterize ([current-deliver-owner c])
              (glowcap_host_session_feed_bytes (session-ptr c) buf (bytes-length got))))
          (host-drain-parked-releases! m)
          (cond
            [(= rc OK)
             (values (drain-host-actions! m) 'done)]
            [(= rc WOULD-BLOCK)
             (values (drain-host-actions! m) 'retry)]
            [else
             (define captured (capture-feed-refusal c rc))
             ;; Park the abort on the FIFO and mark `c` touched so the shared
             ;; drain spine writes it — refusal is a flush, not a private exit.
             (values (drain-effects (list c) '() #f #t) captured)]))))
    (cond
      [(eq? result 'done) (void)]
      [(eq? result 'retry) (loop)]
      [else (raise-feed-refusal result)])))

;; Resume frames the Host held behind the handshake open. Stream sessions may
;; dispatch a retained tail; packet-framed sessions have no hidden tail.
(define (resume-feed! c)
  (define m (session-host c))
  (let loop ()
    (define result
      (with-host-drain m
        (lambda ()
          (guard-open 'session-serve c)
          (define rc
            (parameterize ([current-deliver-owner c])
              (glowcap_host_session_resume_feed (session-ptr c))))
          (host-drain-parked-releases! m)
          (cond
            [(= rc OK)
             (values (drain-host-actions! m) 'done)]
            [(= rc WOULD-BLOCK)
             (values (drain-host-actions! m) 'retry)]
            [else
             (define captured (capture-feed-refusal c rc))
             (values (drain-effects (list c) '() #f #t) captured)]))))
    (cond
      [(eq? result 'done) (void)]
      [(eq? result 'retry) (loop)]
      [else (raise-feed-refusal result)])))

;; The feed refusal choreography, split around the host lock. Under the lock
;; (`capture-feed-refusal`): read the typed cause before another verb can
;; clobber the last-error slot, and park the projected op:abort on the
;; connection's pending-writes FIFO (`take_outbound` is a host verb). The
;; feed returns `c` in `drain-effects.touched` so `run-drain-effects!` writes
;; the abort after the lock (and after the reader gate, when deferred).
;; `raise-feed-refusal` only raises — it never writes.
(define (capture-feed-refusal c rc)
  (define msg (host-last-error))
  (define abort #f)
  (define diagnostics '())
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (set! diagnostics (cons error diagnostics)))])
    (set! abort (session-last-abort c)))
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (set! diagnostics (cons error diagnostics)))])
    (drain-outbound! c))
  (define base
    (if msg (format "glowcap error ~a: ~a" rc msg) (format "glowcap error ~a" rc)))
  (define detail
    (if (null? diagnostics)
        base
        (format "~a [while projecting refusal: ~a]"
                base
                (string-join
                 (map (lambda (diagnostic)
                        (if (exn? diagnostic)
                            (exn-message diagnostic)
                            (format "~a" diagnostic)))
                      (reverse diagnostics))
                 "; "))))
  (define failure
    (exn:fail:glowcap
     (if abort
         (format "~a [~a~a: ~a]" detail (abort-info-domain abort)
                 (if (abort-info-kind abort) (format " ~a" (abort-info-kind abort)) "")
                 (abort-info-message abort))
         detail)
     (current-continuation-marks) rc abort #f #f #f 0))
  (record-session-wire-failure! c failure)
  failure)

(define (raise-feed-refusal refusal)
  (raise refusal))

;; The transport reported end of stream: break every far vow still parked here
;; (their resolutions can never arrive — with the partner's retained abort
;; diagnostic when one was received), classify those settles as closure, and
;; wake every parked pump.
(define (handle-session-eof! c)
  (define ac (session-async c))
  (unless (unbox (async-connection-closed? ac))
    (set-box! (session-transport-lost? c) #t)
    (set-box! (async-connection-closed? ac) #t)
    ;; The core classifies the terminal FAIL completions; this window only
    ;; preserves their drain order.
    (with-handlers ([(lambda (_) #t)
                     (lambda (error)
                       (record-session-wire-failure! c error)
                       (void))])
      (with-session-drain c
        (lambda ()
          (transport-closed-bytes! c #"connection closed"))))
    ;; EOF is terminal ownership, not only a promise notification. Retire the
    ;; native session so the Host's strong session registry cannot retain one
    ;; dead row per disconnected partner.
    (close-session-transport! c)
    (with-handlers ([(lambda (_) #t)
                     (lambda (error)
                       (record-session-wire-failure! c error)
                       (void))])
      (abandon-session! c)))
  (raise-session-wire-failure! c))

;; One reader step. The first step on an open session resumes the frames the
;; Host held behind the handshake hello and returns without
;; waiting, so the resume's deferred effects run before any park. Every later
;; step waits on the transport and the wake event together — the host's
;; progress, plus the deadline alarm when the pump is bounded. 'woke means
;; another thread moved the host or the deadline passed, so the caller
;; re-checks its predicate.
;;
;; Snapshot the wake evt only before the wait. Under the reader, feed parks
;; drain effects (no bump); bumping before the read would wake waiters while
;; this thread still holds the gate. After effects run and the gate clears,
;; `pump-until` bumps once.
(define (pump-read-once! c)
  (define ac (session-async c))
  (define m (session-host c))
  (cond
    [(and (session-open? c) (not (unbox (async-connection-tail-resumed? ac))))
     (set-box! (async-connection-tail-resumed? ac) #t)
     (resume-feed! c)]
    [else
     (define gen (pump-wake-evt m))
     (define got
       (with-handlers ([(lambda (_) #t)
                        (lambda (error)
                          ;; A read interrupted by this Session's own close is
                          ;; merely its wakeup. Every other transport exception
                          ;; is the exact terminal cause.
                          (if (session-closing? c)
                              'woke
                              (begin
                                (set-box! (session-transport-lost? c) #t)
                                (record-session-wire-failure! c error)
                                (cons 'failed error))))])
         ((async-transport-read-some! (async-connection-transport ac)) gen)))
     (cond
       [(eq? got 'woke) (void)]
       [(eof-object? got) (handle-session-eof! c)]
       [(and (pair? got) (eq? (car got) 'failed))
        (handle-session-eof! c)
        (raise-session-wire-failure! c)]
       [else (feed-bytes! c got)])]))

;; Drive the connection until `done` returns non-#f, returning that value.
;; Exactly one thread reads the transport at a time (the reader gate); every
;; other pump on this host parks on the wake event and re-checks. The
;; closed check runs after `done`, so a predicate satisfied by the closure
;; itself (a vow broken by the disconnect, `session-serve`'s own exit) wins over
;; the typed ERR-CLOSED refusal; the deadline is checked last of the three, so
;; a partner that both hung up and overran is reported as the closure it is.
;;
;; Reader contract: under the gate, lock+feed may only queue `drain-effects`.
;; Clears the gate, then runs writes/fires, then bumps — so a waiter never
;; sees a retired generation while the gate is still held, and a blocking
;; write never shares the reader window.
(define (pump-until c done who
                    #:closed-message [closed-message #f]
                    #:timeout-message [timeout-message #f])
  (define m (session-host c))
  (define ac (session-async c))
  ;; A loop-backed session's inbound is held until its embedder serves, and a
  ;; blocking verb pumping here is that announcement as much as session-serve
  ;; is: run the (idempotent) hook so the wait below can ever be answered.
  ((unbox (async-connection-serve-hook ac)))
  (set-box! (async-connection-serve-hook ac) void)
  (define (raise-closed)
    (raise-session-wire-failure! c)
    (raise-glowcap who ERR-CLOSED "~a" (or closed-message "connection closed")))
  (define (raise-timed-out)
    (raise-glowcap who ERR-TIMEOUT "~a" (or timeout-message "the wait timed out")))
  (define (run-reader)
    (define deferred (box no-drain-effects))
    (dynamic-wind
     void
     (lambda ()
       (parameterize ([current-defer-drain-effects deferred])
         (pump-read-once! c)))
     (lambda ()
       (set-box! (async-connection-reader ac) #f)
       ;; The bump advertises state already committed above (reader cleared,
       ;; vows settled by the feed). A break — a timeout wrapped around
       ;; `session-await`, a custodian shutdown — landing between the effects
       ;; and the bump would skip it and strand a waiter spinning on that state.
       ;; The post-thunk fires the bump on a break escape too; effects still run
       ;; first on the normal path, and a spare bump is harmless (waiters
       ;; re-check and re-park).
       (dynamic-wind
        void
        (lambda () (run-drain-effects! m (unbox deferred)))
        (lambda () (host-bump-progress! m))))))
  ;; True when this thread wins the single-reader gate; the CAS is the claim.
  (define (claim-reader?)
    (box-cas! (async-connection-reader ac) #f (current-thread)))
  (let loop ()
    (drain-host! m)
    (define r (done))
    (cond
      [r r]
      [(unbox (async-connection-closed? ac)) (raise-closed)]
      [(pump-deadline-passed?) (raise-timed-out)]
      [(claim-reader?) (run-reader) (loop)]
      [else
       ;; Snapshot under the host lock, then recheck before waiting so a
       ;; released gate cannot retire the generation this waiter will sync.
       (define gen (pump-wake-evt m))
       (cond
         [(done) => (lambda (v) v)]
         [(unbox (async-connection-closed? ac)) (raise-closed)]
         [(pump-deadline-passed?) (raise-timed-out)]
         [(claim-reader?) (run-reader) (loop)]
         [else (sync gen) (loop)])])))

;; Drive a freshly opened connection's keyed handshake to an open session.
;; The signed op:start-session leaves on the first drain-host!; pump-until
;; feeds until session-open?. `timeout-ms` bounds the wait and raises
;; ERR-TIMEOUT when the partner overruns it. Both #f and 0 leave it unbounded:
;; 0 is how the C ABI and the sibling bindings spell "no bound", so a caller
;; passing it through must not land on a deadline of right now.
;; Abandonment on failure stays on finish-establish!.
(define (run-handshake! c [timeout-ms #f])
  (define bound (and timeout-ms (> timeout-ms 0) timeout-ms))
  (drain-host! (session-host c))
  (parameterize ([current-pump-deadline
                  (and bound (+ (current-inexact-milliseconds) bound))])
    (pump-until c (lambda () (session-open? c)) 'connect
                #:closed-message "connection closed during the OCapN handshake"
                #:timeout-message
                (and bound
                     (format "the partner did not finish the OCapN handshake within ~ams"
                             bound)))))
