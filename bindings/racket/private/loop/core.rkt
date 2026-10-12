#lang racket/base
;; The Racket-owned native loop state and event-driving authority. Transport
;; packages compose around this module; it owns the one stepping thread, event
;; queue projection, and failure fanout.

(require ffi/unsafe
         ffi/unsafe/port
         racket/async-channel
         racket/lazy-require
         racket/random
         "../constants.rkt"
         "../abi-value.rkt"
         "../ffi-driver.rkt"
         "../driver-failure.rkt"
         "../errors.rkt"
         "../value.rkt"
         "../locator.rkt"
         "../vat.rkt"
         (combine-in "../host.rkt" "../host/state.rkt")
         "../trace.rkt"
         "../trampoline.rkt"
         "../host-action-gen.rkt"
         "../async.rkt"
         "../pump.rkt"
         "../action.rkt"
         "../promise.rkt"
         (combine-in "../session.rkt" "../session/state.rkt")
         "../transport.rkt")

(lazy-require
 ["../gc.rkt"
  (host-gc-pending?)])

(provide (struct-out driver-loop)
         (struct-out loop-dial-waiter)
         (struct-out loop-listener)
         accepts-terminal
         driver-loop-start!
         loop-background-failed!
         driver-loop-add-provider!
         driver-loop-has-transport?
         check/driver
         loop-running?
         loop-native-live?
         loop-drain!
         pop-events!
         dispatch-events!
         settle-dial-waiter!
         operation-options->c
         settle-listener!
         listener-ready!
         listener-failed!
         listener-closed-exn
         loop-step-wait-ms
         loop-session-release!
         loop-claim-reference-exporter)

;; ── Errors ───────────────────────────────────────────────────────────────────

;; The driver archive's own thread-local last-error slot, symbol-disjoint from
;; the `glowcap_host_*` family's even though one library carries both.
(define (driver-last-error) (read-last-error glowcap_driver_last_error))
(define (check/driver code) (check-with code driver-last-error))

;; ── The loop ─────────────────────────────────────────────────────────────────

;; One stepping native loop over one multi-session host. `handle` is the
;; GlowcapDriverLoop*; `host` is the adopted wrapper `host` whose
;; `driver-loop` field points back here; `event-buf` is the one reused
;; `_GlowcapDriverEvent` pop
;; target (views die at the next pop, so decode copies out immediately);
;; `dials` maps an admitted operation's id to its waiter; `listeners` owns the
;; setup event and accepted-session queue for each listener; `closed-ptrs` records a
;; SESSION_CLOSED handle no wrapper had claimed yet, retaining its exact failure
;; so a later wrap starts closed instead of parking on a dead wire; `state` is binding lifetime only:
;; open, retiring while the native driver owns the session barrier, stopping
;; while teardown joins the park thread, or released after the handle is freed.
(struct driver-loop
  ([handle #:mutable]
   [host #:mutable]
   event-buf
   dials
   listeners
   closed-ptrs
   state
   [failure #:mutable]
   stop-sema
   [park-thread #:mutable]
   [fd #:mutable]))

(struct loop-dial-waiter (sema result))

;; Listener construction is an event, not a ready value. The driver mints the
;; stable id synchronously, but this object settles only when the event queue
;; reports LISTENER_READY, LISTENER_FAILED, or an explicit cancellation.
(struct loop-listener
  (lp id settled outcome state accepts)
  #:transparent
  #:property prop:evt
  (lambda (listener)
    (handle-evt
     (semaphore-peek-evt (loop-listener-settled listener))
     (lambda (_) (unbox (loop-listener-outcome listener))))))

;; Wakes every parked accept when the loop closes, so a server iteration ends
;; instead of waiting on a queue nothing will ever feed again.
(define accepts-terminal (gensym 'loop-accepts-closed))

(define (loop-running? lp)
  (memq (unbox (driver-loop-state lp)) '(open retiring)))

(define (loop-native-live? lp)
  (not (eq? (unbox (driver-loop-state lp)) 'released)))

(define (run-loop-failure-effect! m effect)
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (record-host-runtime-failure! m error)
                     (void))])
    (effect)))

;; A failed background drain is one terminal binding outcome. Complete every
;; waiter before the existing Host worker releases the loop-owned graph.
(define (loop-background-failed! lp error)
  (define state (driver-loop-state lp))
  (define claimed?
    (let claim ()
      (case (unbox state)
        [(open) (if (box-cas! state 'open 'failed) #t (claim))]
        [(retiring) (if (box-cas! state 'retiring 'failed) #t (claim))]
        [(failed stopping released) #f])))
  (when claimed?
    (set-driver-loop-failure! lp error)
    (define m (driver-loop-host lp))
    ;; The loop owns its park and retirement threads. Their first exact
    ;; failure therefore belongs to the adopted Host's explicit close barrier,
    ;; even when automatic teardown reaches that barrier before its caller.
    (record-host-runtime-failure! m error)
    (dynamic-wind
     void
     (lambda ()
       ;; One ill-behaved settlement must not strand its siblings. Secondary
       ;; failures enter the same first-failure latch but cannot replace the
       ;; loop failure that caused this terminal sweep.
       (for ([operation-id (in-list (hash-keys (driver-loop-dials lp)))])
         (run-loop-failure-effect!
          m
          (lambda ()
            (settle-dial-waiter! lp operation-id (cons 'error error)))))
       (for ([listener (in-hash-values (driver-loop-listeners lp))])
         (run-loop-failure-effect!
          m
          (lambda ()
            (settle-listener! listener error 'failed)
            (async-channel-put (loop-listener-accepts listener) error))))
       (hash-clear! (driver-loop-listeners lp))
       (define fires '())
       (run-loop-failure-effect!
        m
        (lambda ()
          (call-with-host
           m
           (lambda ()
             (for ([c (in-hash-values (host-sessions m))])
               (run-loop-failure-effect! m (lambda () (loop-owner-failed! c error))))
             (for ([vow-id (in-list (hash-keys (host-vows m)))])
               (run-loop-failure-effect!
                m
                (lambda ()
                  (set! fires
                        (append fires
                                (settle-vow! m vow-id (cons 'failed error)))))))))))
       (for ([fire (in-list fires)])
         (run-loop-failure-effect! m fire)))
     (lambda ()
       ;; Publication and release cannot be skipped by a secondary failure or
       ;; a break landing during the terminal sweep.
       (parameterize-break
        #f
        (host-bump-progress! m)
        (semaphore-post (driver-loop-stop-sema lp))
        (host-release-after-native-close/async! m))))))

;; ── Transport providers ─────────────────────────────────────────────────────

;; Provider packages are generic to the loop; private implementation tables
;; stay behind the archive ABI.
(define (driver-loop-add-provider! lp package)
  (define-values (code failure)
    (call/driver-failure
     'driver-add-provider
     (lambda (out)
       (glowcap_driver_add_provider (driver-loop-handle lp) package out))))
  (when failure (raise failure))
  (void))

(define (driver-loop-has-transport? lp transport)
  (define name (string->bytes/utf-8 transport))
  (define present (make-bytes 1 0))
  (check/driver
   (glowcap_driver_has_transport
    (driver-loop-handle lp) name (bytes-length name) present))
  (not (zero? (bytes-ref present 0))))

;; ── Parking and stepping ─────────────────────────────────────────────────────

;; Arm the readiness descriptor and stand up the park thread. From here the
;; loop steps whenever native work is ready, with no verb in flight.
(define (driver-loop-start! lp)
  (unless (driver-loop-fd lp)
    (define-values (rc fd) (glowcap_driver_readiness_fd (driver-loop-handle lp)))
    (check/driver rc)
    (set-driver-loop-fd! lp fd)
    (set-driver-loop-park-thread! lp (thread (lambda () (park-run lp))))))

;; The park thread: sleep on the readiness fd (the place's rktio poller wakes
;; the semaphore when it is readable, so every other green thread keeps
;; running), and on each wake run the ordinary drain (GC, parked releases,
;; one zero-timeout step, the event dispatch, the post-lock effects, and the
;; progress bump every parked pump waits on). Descriptor readiness advances
;; I/O; the timeout comes from the native driver's complete nearest-deadline
;; calculation, so Racket never re-encodes which operation needs a clock.
(define (park-run lp)
  (define m (driver-loop-host lp))
  (define fd (driver-loop-fd lp))
  (let loop ()
    (when (loop-running? lp)
      (with-handlers ([exn:fail:loop-drive?
                       (lambda (error) (loop-background-failed! lp error))]
                      [converts-to-broken?
                       (lambda (error) (loop-background-failed! lp error))])
        (drain-host! m))
      (when (loop-running? lp)
        (define sema (unsafe-file-descriptor->semaphore fd 'read))
        (unless sema
          (error 'glowcap-loop "the loop readiness fd cannot be registered for polling"))
        (define stop (semaphore-peek-evt (driver-loop-stop-sema lp)))
        (define progress (host-progress-evt m))
        ;; Snapshot progress before testing the queue. An enqueue before the
        ;; snapshot leaves `host-gc-pending?` true; one after it posts this exact
        ;; generation. Either way the owner cannot sleep past finalizer work.
        (unless (host-gc-pending? m)
          (define wait-ms (loop-step-wait-ms lp))
          (if (negative? wait-ms)
              (sync sema stop progress)
              (sync/timeout (/ wait-ms 1000.0) sema stop progress)))
        (loop))))
  ;; After a native release the fd is gone (release-from-a-fire deregisters
  ;; it first, in `loop-prestop!`'s self arm); deregister only a live one.
  (when (loop-native-live? lp)
    (unsafe-file-descriptor->semaphore fd 'remove)))

;; The loop arm of `drain-host-actions!` (installed below): bracketed
;; zero-timeout steps plus event drains through quiescence, under the host lock
;; the caller already holds. Mid-turn there is no step: behaviors fire inside the
;; enclosing step, and everything a turn enqueued surfaces when it unwinds
;; into this same drain. A released loop drains nothing.
(define (loop-drain! m lp)
  (cond
    [(or (inside-turn?) (not (loop-running? lp))) no-drain-effects]
    [else
     (with-handlers ([exn:fail:glowcap? raise-loop-drive])
       ;; Before a kicked step: parked releases first (a behavior that closed
       ;; its session mid-turn parked the C free), so the step never runs a
       ;; wire the binding has already condemned.
       (host-drain-parked-releases! m)
       (define events
         (parameterize ([current-deliver-owner (driver-loop-host lp)])
           (let step-loop ([acc '()])
             ;; The step is the deliver: behaviors fire inside it, and the
             ;; trampoline latches their turns to this loop's wrapper host
             ;; through the carrier.
             (define rc (glowcap_driver_step (driver-loop-handle lp) 0))
             (cond
               [(= rc WOULD-BLOCK) (reverse acc)]
               [else
                (check/driver rc)
                ;; A behavior may have parked its own session release during
                ;; this step. Retire it before another wire turn can run.
                (host-drain-parked-releases! m)
                (step-loop (pop-events-onto! lp acc))]))))
       (dispatch-events! m lp events))]))

;; These records give every event field a name at the binding boundary. In
;; particular, operation ids and listener ids are different namespaces even
;; though both are carried by the same C record.
(struct driver-event-opened (operation-id session) #:transparent)
(struct driver-event-open-failed (operation-id failure) #:transparent)
(struct driver-event-listener-ready (listener-id) #:transparent)
(struct driver-event-listener-failed (listener-id failure) #:transparent)
(struct driver-event-accepted (listener-id session) #:transparent)
(struct driver-event-session-closed (session failure) #:transparent)
(struct driver-event-completion (action) #:transparent)

(define (decode-driver-event ev)
  (define kind (GlowcapDriverEvent-kind ev))
  (cond
    [(= kind DRIVER-EVENT-OPENED)
     (driver-event-opened (GlowcapDriverEvent-operation-id ev)
                          (GlowcapDriverEvent-session ev))]
    [(= kind DRIVER-EVENT-OPEN-FAILED)
     (driver-event-open-failed
      (GlowcapDriverEvent-operation-id ev)
      (driver-failure<-event ev))]
    [(= kind DRIVER-EVENT-LISTENER-READY)
     (driver-event-listener-ready (GlowcapDriverEvent-listener-id ev))]
    [(= kind DRIVER-EVENT-LISTENER-FAILED)
     (driver-event-listener-failed
      (GlowcapDriverEvent-listener-id ev)
      (driver-failure<-event ev))]
    [(= kind DRIVER-EVENT-ACCEPTED)
     (driver-event-accepted (GlowcapDriverEvent-listener-id ev)
                            (GlowcapDriverEvent-session ev))]
    [(= kind DRIVER-EVENT-SESSION-CLOSED)
     (driver-event-session-closed
      (GlowcapDriverEvent-session ev)
      (and (not (= (GlowcapDriverEvent-primary-result ev) OK))
           (driver-failure<-event ev)))]
    [(= kind DRIVER-EVENT-COMPLETION)
     (driver-event-completion (host-decode-action!
                               (GlowcapDriverEvent-action ev) arg<-c))]
    [else
     (raise-glowcap 'glowcap-loop ERR-INTERNAL
                    "ABI returned unknown loop event kind ~a" kind)]))

;; Drain `glowcap_driver_next_event` until WOULD-BLOCK, decoding each borrowed
;; C record before the next pop invalidates its views.
(define (pop-events-onto! lp acc)
  (define ev (driver-loop-event-buf lp))
  (let loop ([acc acc])
    (define rc (glowcap_driver_next_event (driver-loop-handle lp) ev))
    (cond
      [(= rc WOULD-BLOCK) acc]
      [else
       (check/driver rc)
       (loop (cons (decode-driver-event ev) acc))])))

;; Pop without driving, for listener close's preserve-already-committed rule.
(define (pop-events! lp)
  (reverse (pop-events-onto! lp '())))

;; Dispatch drained events under the host lock, returning the post-lock
;; fires: settle listeners and dead-session retirement, the split
;; the byte-fed drain keeps.
(define (dispatch-events! m lp events)
  (define fires
    (for/fold ([fires '()]) ([e (in-list events)])
      (cond
        [(driver-event-opened? e)
         (define operation-id (driver-event-opened-operation-id e))
         (define ptr (driver-event-opened-session e))
         (unless (settle-dial-waiter! lp operation-id (cons 'ok ptr))
           (loop-session-release! lp ptr))
         fires]
        [(driver-event-open-failed? e)
         (settle-dial-waiter! lp
                              (driver-event-open-failed-operation-id e)
                              (list 'fail (driver-event-open-failed-failure e)))
         fires]
        [(driver-event-listener-ready? e)
         (listener-ready! lp (driver-event-listener-ready-listener-id e))
         fires]
        [(driver-event-listener-failed? e)
         (listener-failed! lp
                           (driver-event-listener-failed-listener-id e)
                           (driver-event-listener-failed-failure e))
         fires]
        [(driver-event-accepted? e)
         (define listener
           (hash-ref (driver-loop-listeners lp)
                     (driver-event-accepted-listener-id e) #f))
         (define ptr (driver-event-accepted-session e))
         (cond
           [listener (async-channel-put (loop-listener-accepts listener) ptr)]
           [else
            ;; An ACCEPTED handle always has an owner. The native close
            ;; contract makes this unreachable after an orderly listener
            ;; drain; release and fail loudly if routing state regresses.
            (loop-session-release! lp ptr)
            (raise-glowcap 'glowcap-loop ERR-INTERNAL
                           "accepted session names unknown listener ~a"
                           (driver-event-accepted-listener-id e))])
         fires]
        [(driver-event-session-closed? e)
         (define ptr (driver-event-session-closed-session e))
         (define driver-fault (driver-event-session-closed-failure e))
         (define result (if driver-fault (driver-failure-primary-result driver-fault) OK))
         (define c (host-session-for-ptr m ptr))
         ;; A driver-side ProtocolAbort is the flat failure family. The Host
         ;; session still owns the exact local refusal member until release;
         ;; snapshot it before the retirement fire invalidates the handle.
         (define abort
           (and c (= result ERR-SESSION)
                (with-handlers ([(lambda (_) #t) (lambda (_error) #f)])
                  (session-last-abort c))))
         (define failure
           (and (not (= result OK))
                (driver-failure-exn 'session driver-fault abort)))
         (cond
           [c
           ;; The pump's EOF choreography, one tier up: record local teardown,
            ;; then retire the dead handle post-lock. The native close already
            ;; broke the far vows and classified their FAIL completions.
            (when failure
              (set-box! (session-close-result c) failure)
              (record-session-wire-failure! c failure))
            (set-box! (session-closing-state c) #t)
            (set-box! (session-transport-lost? c) #t)
            (set-box! (async-connection-closed? (session-async c)) #t)
            (pending-writes-clear! (session-pending-writes c))
            (cons (lambda ()
                    (close-session-transport! c)
                    (with-handlers ([(lambda (_) #t)
                                     (lambda (error)
                                       (record-session-wire-failure! c error)
                                       (void))])
                      (abandon-session! c)))
                  fires)]
           [else
            ;; No wrapper claimed this handle yet (queued on the accept
            ;; channel, or a loop-internal redeem leg). It stays valid until
            ;; released, so record the closure and let a later wrap start
            ;; closed; the loop's release frees stragglers.
            (hash-set! (driver-loop-closed-ptrs lp)
                       (session-key ptr)
                       (or failure #t))
            fires])]
        [(driver-event-completion? e)
         (append (reverse (settle-completion! m (driver-event-completion-action e))) fires)])))
  (drain-effects '() (reverse fires) #f (pair? events)))

;; A COMPLETION carries the byte-fed queue's own SETTLE or FAIL shape; route
;; it through the same vow table. The core's FAIL result is authoritative.
(define (settle-completion! m action)
  (host-dispatch-action!
   action
   (hash
    'settle
    (lambda (act) (settle-vow! m (cadr act) (cons 'ok (caddr act))))
    'fail
    (lambda (act)
      (settle-vow! m
                   (cadr act)
                   (vow-failure-outcome (caddr act) (cadddr act))))
    ;; The loop executes transport-shaped actions inside its steps and
    ;; forwards only completions, so every other kind here is a contract
    ;; break worth failing loud on.
    'dial (lambda (_a) (completion-kind-error 'dial))
    'cancel-dial (lambda (_a) (completion-kind-error 'cancel-dial))
    'flush (lambda (_a) (completion-kind-error 'flush))
    'close (lambda (_a) (completion-kind-error 'close))
    'need-gift-id (lambda (_a) (completion-kind-error 'need-gift-id))
    'resume (lambda (_a) (completion-kind-error 'resume)))))

(define (completion-kind-error kind)
  (raise-glowcap 'glowcap-loop ERR-INVALID-ARGUMENT
                 "a loop COMPLETION event carried a ~a action" kind))

(define (settle-dial-waiter! lp operation-id outcome)
  (define w (hash-ref (driver-loop-dials lp) operation-id #f))
  (hash-remove! (driver-loop-dials lp) operation-id)
  (cond
    [w
     (set-box! (loop-dial-waiter-result w) outcome)
     (semaphore-post (loop-dial-waiter-sema w))
     #t]
    [else #f]))


(define (operation-options->c who options)
  (cond
    [(not options) #f]
    [(transport-operation-options? options)
     (make-GlowcapTransportOperationOptions
      (transport-operation-options-data options)
      (transport-operation-options-size options))]
    [else
     (raise-argument-error who "transport-operation-options?" options)]))

(define (listener-closed-exn who)
  (exn:fail:glowcap
   (format "~a: listener closed during setup" who)
   (current-continuation-marks)
   ERR-CLOSED
   #f #f #f #f 0))

(define (settle-listener! listener outcome terminal-state)
  (when (box-cas! (loop-listener-state listener) 'pending terminal-state)
    (set-box! (loop-listener-outcome listener) outcome)
    (semaphore-post (loop-listener-settled listener))
    #t))

(define (listener-ready! lp listener-id)
  (define listener (hash-ref (driver-loop-listeners lp) listener-id #f))
  (when listener
    ;; A close claims the pending state before asking the driver to cancel it.
    ;; A late committed READY is therefore ignored without reopening a closed
    ;; listener or exposing a handle the caller has already retired.
    (settle-listener! listener listener 'ready)))

(define (listener-failed! lp listener-id failure)
  (define listener (hash-ref (driver-loop-listeners lp) listener-id #f))
  (when listener
    (define error (driver-failure-exn 'listen failure #f))
    (define setup-failed?
      (settle-listener! listener error 'failed))
    (define active-failed?
      (and (not setup-failed?)
           (box-cas! (loop-listener-state listener) 'ready 'failed)))
    (define closing-failed?
      (and (not setup-failed?) (not active-failed?)
           (box-cas! (loop-listener-state listener) 'closing 'failed)))
    (when (or setup-failed? active-failed? closing-failed?)
      (when (or active-failed? closing-failed?)
        (set-box! (loop-listener-outcome listener) error))
      (hash-remove! (driver-loop-listeners lp) listener-id)
      (async-channel-put (loop-listener-accepts listener) error))))


;; How long a loop close driver may park before stepping again: milliseconds
;; until the nearest pending-work deadline (close grace, session close grace,
;; a dial or listener setup budget), clamped at zero, or -1 when no finite
;; deadline is pending and readiness alone advances the loop. An expiry takes
;; effect only inside a step, so the timer arm of each driver below is what
;; applies it.
(define (loop-step-wait-ms lp)
  (define-values (rc wait-ms)
    (glowcap_driver_step_wait_ms (driver-loop-handle lp)))
  (check/driver rc)
  wait-ms)

;; A loop-owned session's release: through the loop, so the native tier
;; unhooks the wire it is polling. After native teardown the handles are
;; already freed with the loop; the guard keeps a straggling finalizer from
;; touching them.
(define (loop-session-release! lp ptr)
  (when (loop-native-live? lp)
    (check/driver (glowcap_driver_session_release (driver-loop-handle lp) ptr))
    (hash-remove! (driver-loop-closed-ptrs lp) (session-key ptr))))

(define (loop-claim-reference-exporter lp reference)
  (define-values (rc ptr)
    (glowcap_driver_claim_reference_exporter (driver-loop-handle lp) reference))
  (check/driver rc)
  ptr)
