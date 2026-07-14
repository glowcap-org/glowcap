#lang racket/base
;; Internal: the byte-fed embedder pump choreography over the host
;; (libpancake_driver, ADR-0072 / ADR-0079).
;;
;; Owns the connection byte path the embedder contract leaves to the binding:
;; the keyed handshake, read raw bytes off the transport, hand them to the
;; core's stream delimiter (`pancake_host_session_feed_bytes`, which owns framing),
;; write what `take_outbound` drains, the feed-refusal path (`last_abort` /
;; abort), and the EOF teardown that `break_far_vows` classifies as closure.
;; CapTP verbs stay in `private/session.rkt`; the host action switch
;; (`drain-host-actions!`) lives in `private/action.rkt`. This module is
;; required by session; the public barrel reaches pump only through session
;; verbs / dogfood plumbing.

(require ffi/unsafe
         racket/async-channel
         racket/lazy-require
         "constants.rkt"
         "ffi-ocapn.rkt"
         "ffi-driver.rkt"
         "ffi-shared.rkt"
         "errors.rkt"
         "value.rkt"
         "async.rkt"
         "host.rkt"
         "vat.rkt")

;; Session owns the `session` type and the lock-drain choreography
;; (`with-host-drain` / `drain-host!` / …); action owns the drain switch.
;; Lazy-require breaks the session ↔ pump and action ↔ pump cycles: session
;; and action eagerly require this module for the byte path / FLUSH arm.
(lazy-require
 ["session.rkt"
  (session-ptr
   session-async
   session-host
   session-pending-writes
   session-write-gate
   session-released?
   session-open?
   guard-open
   with-host-drain
   with-breaking-drain
   drain-host!)]
 ["action.rkt"
  (drain-host-actions!)])

(provide drain-effects
         drain-effects-touched
         drain-effects-fires
         drain-effects?
         no-drain-effects
         drain-outbound!
         write-pending!
         feed-inbox!
         feed-bytes!
         capture-feed-refusal
         raise-feed-refusal
         handle-session-eof!
         pump-read-once!
         pump-until
         run-handshake!
         session-last-abort
         break-far-vows-bytes!)

;; What one locked drain hands back to run once the host lock releases: the
;; connections whose outbound was drained, and the deferred fires — settled
;; vows' listeners, dial executors, condemned-connection closes. Everything
;; here must run post-lock: a socket write can block, a dial is a connect
;; syscall plus a whole keyed handshake, and a listener is application code
;; that may pump. A fire still runs inside the reader window of the
;; connection whose feed produced it, so a listener may pump *other*
;; connections but must only enqueue on this one.
(struct drain-effects (touched fires))
(define no-drain-effects (drain-effects '() '()))

;; The typed cause of this CapTP session's most recent local dispatch failure, or
;; #f — the host counterpart of the Zig `Peer.lastAbort`, read through the
;; shared `PancakeLastAbort` layout. Feed-refusal owns the reader; Session
;; re-exports the name for dogfood/plumbing.
(define (session-last-abort c)
  (define out (make-PancakeLastAbort 0 0 #f 0 #f 0 #f 0))
  (define rc (pancake_host_session_last_abort (session-ptr c) out))
  (cond
    [(= rc WOULD-BLOCK) #f]
    [else (check/host rc) (abort-info<-c out)]))

;; Host FFI for breaking far vows parked on `c`. Caller owns the
;; `with-breaking-drain` window so FAIL completions classify as closure.
(define (break-far-vows-bytes! c bs)
  (check/host (pancake_host_session_break_far_vows
               (session-ptr c) (pin-immobile bs) (bytes-length bs))))

;; Pop every encoded outbound frame on `c` into its pending-writes FIFO, in
;; queue order. Caller holds the host lock (`take_outbound` is a host verb);
;; the socket write happens after the lock releases, through `write-pending!`.
(define (drain-outbound! c)
  (unless (session-released? c)
    (let loop ()
      (define mf (make-PancakeManagedFrame #f 0 0 #f #f))
      (define rc (pancake_host_session_take_outbound (session-ptr c) mf))
      (cond
        [(= rc WOULD-BLOCK) (void)]
        [else
         (check/host rc)
         (define out (bytes<-c (PancakeManagedFrame-bytes mf) (PancakeManagedFrame-len mf)))
         (pancake_managed_frame_release mf)
         (async-channel-put (session-pending-writes c) out)
         (loop)]))))

;; Write everything parked on `c`'s pending-writes FIFO to the transport,
;; flushing once, serialized by the connection's write gate. Runs outside the
;; host lock; a dead transport's write error is the caller's to tolerate.
(define (write-pending! c)
  (unless (session-released? c)
    (define tr (async-connection-transport (session-async c)))
    (call-with-semaphore
     (session-write-gate c)
     (lambda ()
       (let loop ([wrote? #f])
         (define out (async-channel-try-get (session-pending-writes c)))
         (cond
           [out ((async-transport-write-frame! tr) out) (loop #t)]
           [wrote? ((async-transport-flush! tr))]
           [else (void)]))))))

;; Feed the connection's buffered inbound bytes into the host through the
;; core's stream delimiter (`pancake_host_session_feed_bytes`): the session's
;; codec splits each complete frame off the front — both codecs, both frame
;; shapes, the frame cap enforced during the scan — and dispatches it (behavior
;; and settle callbacks fire inside), then the actions the dispatch queued
;; drain. Only the unconsumed tail stays in the inbox. Returns the consumed
;; byte count, zero when the inbox is empty or holds only a partial frame. On
;; a refused stream the peer has already projected a typed op:abort; write it
;; so the partner hears why, then raise the typed failure carrying the
;; connection's `abort-info`.
(define (feed-inbox! c)
  (define ac (session-async c))
  (define bs (async-connection-inbox ac))
  (cond
    [(zero? (bytes-length bs)) 0]
    [else
     (guard-open 'session-serve c)
     (define m (session-host c))
     ;; Two values ride out of the locked drain: the consumed byte count and
     ;; the refusal captured under the lock (raised only after the effects ran
     ;; and the pumps woke, so the projected op:abort is already parked).
     (define-values (consumed refusal)
       (with-host-drain m
         (lambda ()
           (define buf (pin-immobile bs))
           (define-values (rc n)
             (pancake_host_session_feed_bytes (session-ptr c) buf (bytes-length bs)))
           (cond
             [(= rc OK)
              (async-consume! ac n)
              (host-drain-parked-releases! m)
              (values (drain-host-actions! m) n #f)]
             [else (values no-drain-effects 0 (capture-feed-refusal c rc))]))))
     (when refusal (raise-feed-refusal c refusal))
     consumed]))

;; Append freshly read bytes onto the inbox and feed it — the pump's
;; fill-then-feed step, and the scripted smoke's byte-injection seam.
(define (feed-bytes! c got)
  (async-fill! (session-async c) got)
  (feed-inbox! c))

;; The feed refusal choreography, split around the host lock. Under the lock
;; (`capture-feed-refusal`): read the typed cause before another verb can
;; clobber the last-error slot, and park the projected op:abort on the
;; connection's pending-writes FIFO (`take_outbound` is a host verb). After
;; the lock releases (`raise-feed-refusal`): write the abort so the partner
;; hears why — a socket write must never run under the host lock, teardown
;; included — then raise the typed failure carrying the `abort-info`.
(define (capture-feed-refusal c rc)
  (define msg (host-last-error))
  (define abort (session-last-abort c))
  (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
  (list rc msg abort))

(define (raise-feed-refusal c refusal)
  (with-handlers ([converts-to-broken? void]) (write-pending! c))
  (define rc (car refusal))
  (define msg (cadr refusal))
  (define abort (caddr refusal))
  (define base
    (if msg (format "pancake error ~a: ~a" rc msg) (format "pancake error ~a" rc)))
  (raise (exn:fail:pancake
          (if abort
              (format "~a [~a~a: ~a]" base (abort-info-domain abort)
                      (if (abort-info-kind abort) (format " ~a" (abort-info-kind abort)) "")
                      (abort-info-message abort))
              base)
          (current-continuation-marks) rc abort)))

;; The transport reported end of stream: break every far vow still parked here
;; (their resolutions can never arrive — with the partner's retained abort
;; diagnostic when one was received), classify those settles as closure, and
;; wake every parked pump.
(define (handle-session-eof! c)
  (define ac (session-async c))
  (unless (unbox (async-connection-closed? ac))
    (set-box! (async-connection-closed? ac) #t)
    ;; The breaking window: the FAIL completions the break queues classify as
    ;; closure.
    (with-breaking-drain c
      (lambda ()
        (break-far-vows-bytes! c #"connection closed")))))

;; One reader step: feed whatever the inbox already buffers; when that made no
;; progress (empty, or a partial frame needing more bytes), wait on the
;; transport and the host's progress event together — 'woke means another
;; thread moved the host, so the caller re-checks its predicate.
(define (pump-read-once! c gen)
  (define ac (session-async c))
  (when (zero? (feed-inbox! c))
    (define got
      ;; A port closed under us (another thread's `session-close!`) is an
      ;; end of stream, not a fault.
      (with-handlers ([exn:fail? (lambda (_e) eof)])
        ((async-transport-fill-inbox! (async-connection-transport ac)) gen)))
    (cond
      [(eq? got 'woke) (void)]
      [(eof-object? got) (handle-session-eof! c)]
      [else (feed-bytes! c got)])))

;; Drive the connection until `done` returns non-#f, returning that value.
;; Exactly one thread reads the transport at a time (the reader gate); every
;; other pump on this host parks on the progress event and re-checks. The
;; closed check runs after `done`, so a predicate satisfied by the closure
;; itself (a vow broken by the disconnect, `session-serve`'s own exit) wins over
;; the typed ERR-CLOSED refusal.
(define (pump-until c done who #:closed-message [closed-message #f])
  (define m (session-host c))
  (define ac (session-async c))
  (let loop ()
    (drain-host! m)
    (define gen (host-progress-evt m))
    (define r (done))
    (cond
      [r r]
      [(unbox (async-connection-closed? ac))
       (raise-pancake who ERR-CLOSED "~a" (or closed-message "connection closed"))]
      [(box-cas! (async-connection-reader ac) #f (current-thread))
       (dynamic-wind
        void
        (lambda () (pump-read-once! c gen))
        (lambda ()
          (set-box! (async-connection-reader ac) #f)
          (host-bump-progress! m)))
       (loop)]
      [else (sync gen) (loop)])))

;; Drive a freshly opened connection's keyed handshake to an open session.
;; The signed op:start-session leaves on the first drain-host!; pump-until
;; feeds until session-open?. Abandonment on failure stays on finish-establish!.
(define (run-handshake! c)
  (drain-host! (session-host c))
  (pump-until c (lambda () (session-open? c)) 'connect
              #:closed-message "connection closed during the OCapN handshake"))
