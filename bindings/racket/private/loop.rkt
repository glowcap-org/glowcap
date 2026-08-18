#lang racket/base
;; Internal: the native loop tier (ADR-0112) — the `pancake_driver_*` face of
;; libpancake_driver, over transport packages composed by product modules.
;;
;; One green thread drives one loop. Every Racket green thread shares the
;; place's one OS thread, so the archive's thread-affinity contract is met by
;; construction, and the reentrant host lock serializes verb kicks against the
;; park thread's steps. The choreography is the settled one: park on the
;; loop's one readiness descriptor (`unsafe-file-descriptor->semaphore`), step
;; with a ZERO timeout when it
;; signals — a positive native park would freeze every green thread on the
;; place — and drain the one event queue (OPENED / OPEN_FAILED / ACCEPTED /
;; SESSION_CLOSED / COMPLETION) until WOULD-BLOCK. An in-flight dial's budget
;; expiry is discovered only inside a step, never by the kernel set, so the
;; park is a bounded ticker while dials are in flight.
;;
;; The loop arm of `drain-host-actions!` routes every existing drain site
;; here (`loop-drain-hook`), so a top-level verb's kick steps the loop under
;; the same lock-and-effects spine the byte-fed drain uses, and
;; `pancake_host_pump_drain` never runs beside the loop. Behaviors fire
;; inside `pancake_driver_step` exactly as they fire inside a byte-fed feed,
;; so each step is bracketed as the deliver it is: `current-deliver-session`
;; carries a host-only step carrier, and parked releases drain before a
;; kicked step. The wrapper host is adopted over the loop's own native host
;; (through `pancake_driver_take_host`); the loop is its one release authority, and every
;; loop-owned session releases through `pancake_driver_session_release`.

(require ffi/unsafe
         ffi/unsafe/port
         racket/async-channel
         racket/random
         "constants.rkt"
         "abi-value.rkt"
         "ffi-driver.rkt"
         "driver-failure.rkt"
         "errors.rkt"
         "value.rkt"
         "locator.rkt"
         "vat.rkt"
         "host.rkt"
         "trace.rkt"
         "trampoline.rkt"
         "host-action-gen.rkt"
         "async.rkt"
         "pump.rkt"
         "action.rkt"
         "promise.rkt"
         "session.rkt"
         "transport.rkt")

(provide open-driver-loop
         driver-loop?
         driver-loop-host
         driver-loop-start!
         driver-loop-abort!
         loop-background-failed!
         driver-loop-add-provider!
         driver-loop-has-transport?
         loop-listen!
         loop-listener-ready!
         loop-listener-locator
         loop-listener-restoration-state
         loop-listener-advertise!
         loop-listener-select!
         loop-listener-close!
         loop-connect-session
         make-loop-server
         loop-server?
         loop-server-time-travel?
         loop-server-locator
         loop-server-advertise!
         loop-server-accept
         loop-server-close!
         loop-server-host)

;; ── Errors ───────────────────────────────────────────────────────────────────

;; The driver archive's own thread-local last-error slot, symbol-disjoint from
;; the `pancake_host_*` family's even though one library carries both.
(define (driver-last-error) (read-last-error pancake_driver_last_error))
(define (check/driver code) (check-with code driver-last-error))

;; ── The loop ─────────────────────────────────────────────────────────────────

;; One stepping native loop over one multi-session host. `handle` is the
;; PancakeDriverLoop*; `host` is the adopted wrapper `host` whose
;; `driver-loop` field points back here; `carrier` is the step-deliver
;; bracket below; `event-buf` is the one reused `_PancakeDriverEvent` pop
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
   [carrier #:mutable]
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

(define (fresh-event-buf)
  (make-PancakeDriverEvent
   0 0 0 0 0 0 0 0 0 0 0 #f
   (make-PancakeHostAction
    0 0 #f
    (make-PancakeArgument 0 0 0 0.0 #f 0 (make-PancakeReference 0) #f 0)
    #f 0 0)
   #f 0 #f 0))

;; What a loop step's behavior callbacks read as the arriving deliver context
;; (`current-deliver-session`): enough session shape for the turn bracket —
;; `session-host` for turn-time spawn and `host-defer-turn` — and nothing
;; else. Never registered, never pumped; its transport parks and yields.
(define (make-step-carrier m)
  (session (make-async-connection
            (async-transport (lambda (_frame) (void)) void
                             (lambda (wake-evt) (sync wake-evt) 'woke) void))
	           #f m #f
	           (make-pending-writes 1)
	           (make-semaphore 1) (box #f) (box OK)
	           (box #f) (box #f) (box #f) (box #f)))

;; Create the loop and adopt its wrapper host. The seed is the host
;; constructor's 64-byte contract: the durable identity, then a fresh
;; session-key root drawn here, at this binding's entropy boundary
;; (ADR-0097). A zero wait budget explicitly selects the runtime's unbounded
;; budget; defaults remain finite.
(define (open-driver-loop #:seed [seed #f]
                          #:codec [codec 'syrup]
                          #:captp-version [captp-version 'v1_0]
                          #:features [features 'full]
                          #:wire-buffer-bytes [wire-buffer-bytes DRIVER-DEFAULT-WIRE-BUFFER-BYTES]
                          #:max-pending-opens [max-pending-opens DRIVER-DEFAULT-MAX-PENDING-OPENS]
                          #:handshake-ms [handshake-ms DRIVER-DEFAULT-HANDSHAKE-MS]
                          #:listener-setup-ms [listener-setup-ms DRIVER-DEFAULT-LISTENER-SETUP-MS]
                          #:settle-ms [settle-ms DRIVER-DEFAULT-SETTLE-MS]
                          #:host [supplied-host #f])
  (when (and supplied-host (host-loop-of supplied-host))
    (raise-pancake 'open-driver-loop ERR-INVALID-ARGUMENT
                   "the supplied Host already belongs to a driver loop"))
  (define durable
    (bytes->immutable-bytes
     (or seed (and supplied-host (host-seed supplied-host)) (crypto-random-bytes 32))))
  (when (and supplied-host seed (not (bytes=? seed (host-seed supplied-host))))
    (raise-pancake 'open-driver-loop ERR-INVALID-ARGUMENT
                   "the supplied Host seed conflicts with the loop seed"))
  (define m
    (or supplied-host
        (make-host durable #:codec codec #:captp-version captp-version
                   #:features features)))
  ;; Allocate every Racket-owned part before the native ownership transfer.
  ;; Transfer and attachment form one break-masked commit, so no break can
  ;; observe native ownership before this prepared owner is reachable.
  (define lp
    (driver-loop #f m (make-step-carrier m) (fresh-event-buf)
                 (make-hash) (make-hash) (make-hash)
                 (box 'open) #f (make-semaphore 0) #f #f))
  ;; Native adoption is the transaction. No Racket Host field changes until
  ;; the call succeeds, so an error leaves the Host byte-fed and live.
  (define options
    (make-PancakeDriverOptions DRIVER-OPTIONS-ABI-VERSION (ctype-sizeof _PancakeDriverOptions)
                               wire-buffer-bytes max-pending-opens
                               handshake-ms listener-setup-ms settle-ms))
  (define adopted? #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (define cleanup
                       (with-handlers ([(lambda (_) #t) values])
                         (cond
                           [adopted? (driver-loop-abort! lp)]
                           [(not supplied-host) (host-close! m)])
                         #f))
                     (raise (if cleanup
                                (retain-cleanup-failure e cleanup)
                                e)))])
    (parameterize-break #f
      (define-values (rc h)
        (pancake_driver_take_host (host-ptr m) options))
      (check/driver rc)
      (set-driver-loop-handle! lp h)
      (set-box! (host-driver-loop m) lp)
      (set! adopted? #t))
    lp))

;; Tear a loop down on a construction failure path: the wrapper host is
;; already adopted, so its release is the one teardown.
(define (driver-loop-abort! lp)
  (host-close! (driver-loop-host lp)))

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
       (pancake_driver_add_provider (driver-loop-handle lp) package out))))
  (when failure (raise failure))
  (void))

(define (driver-loop-has-transport? lp transport)
  (define name (string->bytes/utf-8 transport))
  (define present (make-bytes 1 0))
  (check/driver
   (pancake_driver_has_transport
    (driver-loop-handle lp) name (bytes-length name) present))
  (not (zero? (bytes-ref present 0))))

;; ── Parking and stepping ─────────────────────────────────────────────────────

;; Arm the readiness descriptor and stand up the park thread. From here the
;; loop steps whenever native work is ready, with no verb in flight.
(define (driver-loop-start! lp)
  (unless (driver-loop-fd lp)
    (define-values (rc fd) (pancake_driver_readiness_fd (driver-loop-handle lp)))
    (check/driver rc)
    (set-driver-loop-fd! lp fd)
    (set-driver-loop-park-thread! lp (thread (lambda () (park-run lp))))))

;; The park thread: sleep on the readiness fd (the place's rktio poller wakes
;; the semaphore when it is readable, so every other green thread keeps
;; running), and on each wake run the ordinary drain — GC, parked releases,
;; one zero-timeout step, the event dispatch, the post-lock effects, and the
;; progress bump every parked pump waits on. Descriptor readiness advances
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
          (error 'pancake-loop "the loop readiness fd cannot be registered for polling"))
        (define stop (semaphore-peek-evt (driver-loop-stop-sema lp)))
        (define wait-ms (loop-step-wait-ms lp))
        (if (negative? wait-ms)
            (sync sema stop)
            (sync/timeout (/ wait-ms 1000.0) sema stop))
        (loop))))
  ;; After a native release the fd is gone (release-from-a-fire deregisters
  ;; it first, in `loop-prestop!`'s self arm); deregister only a live one.
  (when (loop-native-live? lp)
    (unsafe-file-descriptor->semaphore fd 'remove)))

;; The loop arm of `drain-host-actions!` (installed below): bracketed
;; zero-timeout steps plus event drains through quiescence, under the host lock
;; the caller already holds. Mid-turn there is no step — behaviors fire inside the
;; enclosing step, and everything a turn enqueued surfaces when it unwinds
;; into this same drain — and a released loop drains nothing.
(define (loop-drain! m lp)
  (cond
    [(or (inside-turn?) (not (loop-running? lp))) no-drain-effects]
    [else
     (with-handlers ([exn:fail:pancake? raise-loop-drive])
       ;; Before a kicked step: parked releases first (a behavior that closed
       ;; its session mid-turn parked the C free), so the step never runs a
       ;; wire the binding has already condemned.
       (host-drain-parked-releases! m)
       (define events
         (parameterize ([current-deliver-session (driver-loop-carrier lp)])
           (let step-loop ([acc '()])
             ;; The step is the deliver: behaviors fire inside it, and the
             ;; trampoline latches their turns to this loop's wrapper host
             ;; through the carrier.
             (define rc (pancake_driver_step (driver-loop-handle lp) 0))
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
  (define kind (PancakeDriverEvent-kind ev))
  (cond
    [(= kind DRIVER-EVENT-OPENED)
     (driver-event-opened (PancakeDriverEvent-operation-id ev)
                          (PancakeDriverEvent-session ev))]
    [(= kind DRIVER-EVENT-OPEN-FAILED)
     (driver-event-open-failed
      (PancakeDriverEvent-operation-id ev)
      (driver-failure<-event ev))]
    [(= kind DRIVER-EVENT-LISTENER-READY)
     (driver-event-listener-ready (PancakeDriverEvent-listener-id ev))]
    [(= kind DRIVER-EVENT-LISTENER-FAILED)
     (driver-event-listener-failed
      (PancakeDriverEvent-listener-id ev)
      (driver-failure<-event ev))]
    [(= kind DRIVER-EVENT-ACCEPTED)
     (driver-event-accepted (PancakeDriverEvent-listener-id ev)
                            (PancakeDriverEvent-session ev))]
    [(= kind DRIVER-EVENT-SESSION-CLOSED)
     (driver-event-session-closed
      (PancakeDriverEvent-session ev)
      (and (not (= (PancakeDriverEvent-primary-result ev) OK))
           (driver-failure<-event ev)))]
    [(= kind DRIVER-EVENT-COMPLETION)
     (driver-event-completion (host-decode-action!
                               (PancakeDriverEvent-action ev) arg<-c))]
    [else
     (raise-pancake 'pancake-loop ERR-INTERNAL
                    "ABI returned unknown loop event kind ~a" kind)]))

;; Drain `pancake_driver_next_event` until WOULD-BLOCK, decoding each borrowed
;; C record before the next pop invalidates its views.
(define (pop-events-onto! lp acc)
  (define ev (driver-loop-event-buf lp))
  (let loop ([acc acc])
    (define rc (pancake_driver_next_event (driver-loop-handle lp) ev))
    (cond
      [(= rc WOULD-BLOCK) acc]
      [else
       (check/driver rc)
       (loop (cons (decode-driver-event ev) acc))])))

;; Pop without driving, for listener close's preserve-already-committed rule.
(define (pop-events! lp)
  (reverse (pop-events-onto! lp '())))

;; Dispatch drained events under the host lock, returning the post-lock
;; fires: settle listeners and dead-session retirement, exactly the split
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
            (raise-pancake 'pancake-loop ERR-INTERNAL
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
  (raise-pancake 'pancake-loop ERR-INVALID-ARGUMENT
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

;; ── Dial ─────────────────────────────────────────────────────────────────────

;; Begin a nonblocking dial, kick a step so the handshake starts advancing, and park for
;; the outcome. The loop's handshake budget bounds the whole dial natively,
;; and both the park thread and the co-stepping waiter below arm exactly the
;; deadline returned by `pancake_driver_step_wait_ms`. The driver's event
;; result is the authoritative failure category; its message remains
;; diagnostic detail.
(define (operation-options->c who options)
  (cond
    [(not options) #f]
    [(transport-operation-options? options)
     (make-PancakeTransportOperationOptions
      (transport-operation-options-data options)
      (transport-operation-options-size options))]
    [else
     (raise-argument-error who "transport-operation-options?" options)]))

(define (loop-dial! lp locator-uri [options #f])
  (define m (driver-loop-host lp))
  (define w (loop-dial-waiter (make-semaphore 0) (box #f)))
  (define c-options (operation-options->c 'runtime-connect options))
  (with-host-drain m
    (lambda ()
      (define-values (rc operation-id)
        (call-with-locator-view
         locator-uri
         (lambda (view)
           (pancake_driver_dial (driver-loop-handle lp) view c-options))))
      (check/driver rc)
      (hash-set! (driver-loop-dials lp) operation-id w)
      (drain-host-actions! m)))
  ;; The park thread may be in an unbounded fd park from before this dial
  ;; existed; the loop's one cross-thread verb makes the fd readable so it
  ;; rebuilds its wait from the newly installed native deadline.
  (check/driver (pancake_driver_wake (driver-loop-handle lp)))
  ;; Co-stepping park: a listener fire may run this dial on the park thread
  ;; itself, and then nobody else would step the handshake forward. Wait on
  ;; the loop descriptor and pancake's nearest deadline beside the result;
  ;; either wake runs the ordinary drain without a fixed polling cadence.
  (define fd-sema
    (unsafe-file-descriptor->semaphore (driver-loop-fd lp) 'read))
  (unless fd-sema
    (error 'connect "the loop readiness fd cannot be registered for polling"))
  (let wait ()
    (define result-sema (loop-dial-waiter-sema w))
    (define wait-ms (loop-step-wait-ms lp))
    (define woke
      (if (negative? wait-ms)
          (sync result-sema fd-sema)
          (sync/timeout (/ wait-ms 1000.0) result-sema fd-sema)))
    (unless (eq? woke result-sema)
      (drain-host! m)
      (wait)))
  (define r (unbox (loop-dial-waiter-result w)))
  (case (car r)
    [(ok) (cdr r)]
    [(fail)
     (raise (driver-failure-exn 'connect (cadr r) #f))]
    [(error) (raise (cdr r))]
    [else (raise-pancake 'connect ERR-CLOSED "the loop closed before the dial settled")]))

;; The loop-backed session transport: the native loop owns the wire, so
;; there is nothing to write, flush, read, or close here. A read parks on
;; the wake event and reports progress; teardown runs through
;; `abandon-session!`, whose release routes through the loop.
(define (loop-transport)
  (async-transport
   (lambda (_frame) (void))
   void
   (lambda (wake-evt) (sync wake-evt) 'woke)
   void))

;; Wrap a loop-minted session handle as the public `session` over the
;; adopted wrapper host: every session verb, vow, and trampoline works on it,
;; with the native loop as the transport and the drain. The handshake
;; already ran inside the loop's steps, so the session arrives open and the
;; byte pump's tail-resume never applies.
(define (wrap-loop-session lp ptr time-travel?)
  (define m (driver-loop-host lp))
  (call-with-host m
    (lambda ()
      (define c (build-session m ptr (loop-transport) time-travel?))
      (set-box! (async-connection-tail-resumed? (session-async c)) #t)
      ;; Post-open setup happens between accept (or dial) and serve; the hook
      ;; is how serve tells the loop to start delivering this session's
      ;; inbound (early bytes replay in order). Idempotent on the native side.
      (set-box! (async-connection-serve-hook (session-async c))
                (lambda ()
                  (check/driver (pancake_driver_session_serve
                                 (driver-loop-handle lp) ptr))))
      (define terminal (hash-ref (driver-loop-closed-ptrs lp) (session-key ptr) #f))
      (when terminal
        (hash-remove! (driver-loop-closed-ptrs lp) (session-key ptr))
        (when (exn? terminal) (set-box! (session-close-result c) terminal))
        (set-box! (async-connection-closed? (session-async c)) #t))
      c)))

;; Dial through the loop and wrap the opened session.
(define (loop-connect-session lp locator-uri [options #f])
  (wrap-loop-session lp (loop-dial! lp locator-uri options) #f))

;; ── Listen and accept ────────────────────────────────────────────────────────

(define (listener-closed-exn who)
  (exn:fail:pancake
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
    (when (or setup-failed? active-failed?)
      (when active-failed?
        (set-box! (loop-listener-outcome listener) error))
      (hash-remove! (driver-loop-listeners lp) listener-id)
      (async-channel-put (loop-listener-accepts listener) error))))

(define (loop-listener-ready! listener)
  (define outcome (sync listener))
  (cond
    [(eq? outcome listener) listener]
    [(exn? outcome) (raise outcome)]
    [else
     (raise-pancake 'pancake-loop ERR-INTERNAL
                    "listener setup event produced an invalid outcome")]))

(define (require-listener-ready listener)
  (unless (eq? (unbox (loop-listener-state listener)) 'ready)
    (raise-pancake 'pancake-loop ERR-INVALID-ARGUMENT
                   "listener setup has not settled"))
  listener)

;; Bind one of the loop's per-transport listeners. The kernel's designator (the bound
;; host:port, an ephemeral port resolved) reads back through the canonical
;; locator; listen policy — wildcard refusal, the
;; advertised address — stays with the public `listen` in `listen.rkt`.
(define (loop-listen! lp transport designator [options #f])
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define c-options (operation-options->c 'listen options))
  (define-values (rc listener-id)
    (pancake_driver_listen (driver-loop-handle lp)
                           (pin-immobile tb) (bytes-length tb)
                           (pin-immobile db) (bytes-length db)
                           c-options))
  (check/driver rc)
  (define listener
    (loop-listener lp listener-id (make-semaphore 0) (box #f) (box 'pending)
                   (make-async-channel)))
  (hash-set! (driver-loop-listeners lp) listener-id listener)
  ;; A listener added after the resident park is armed may begin in a pending
  ;; transport state. Wake that park so LISTENER_READY/FAILED can be observed;
  ;; the initial listener is started by `driver-loop-start!` below its caller.
  (when (driver-loop-fd lp)
    (check/driver (pancake_driver_wake (driver-loop-handle lp))))
  listener)

(define (loop-listener-locator lp listener)
  (require-listener-ready listener)
  (define view (make-PancakeLocatorView 0 0 #f 0 #f 0 #f 0 0))
  (define rc
    (pancake_driver_listener_locator (driver-loop-handle lp)
                                     (loop-listener-id listener) view))
  (check/driver rc)
  (clone-locator-view view))

;; Copy opaque provider state through the driver's size-query ABI. The loop
;; owns only the mechanics: callers decide what the returned bytes mean.
(define (loop-listener-restoration-state lp listener)
  (require-listener-ready listener)
  (define (query cap)
    (define out (and (> cap 0) (out-immobile cap)))
    (define-values (rc needed)
      (pancake_driver_listener_restoration_state
       (driver-loop-handle lp)
       (loop-listener-id listener)
       out
       cap))
    (values rc needed out))
  (define-values (rc needed _out) (query 0))
  (cond
    [(= rc OK) #""]
    [(= rc ERR-BUFFER-TOO-SMALL)
     (let copy ([capacity (max 1 needed)])
       (define-values (copy-rc copied out) (query capacity))
       (cond
         [(= copy-rc OK)
          (when (> copied capacity)
            (raise-pancake 'loop-listener-restoration-state ERR-INTERNAL
                           "driver returned restoration state larger than its buffer"))
          (bytes<-c out copied)]
         [(= copy-rc ERR-BUFFER-TOO-SMALL)
          (copy (max (add1 capacity) copied))]
         [else (check/driver copy-rc)]))]
    [else (check/driver rc)]))

(define (loop-listener-advertise! lp listener locator-uri)
  (require-listener-ready listener)
  (call-with-locator-view
   locator-uri
   (lambda (view)
      (check/driver
       (pancake_driver_listener_advertise
        (driver-loop-handle lp) (loop-listener-id listener) view)))))

(define (loop-listener-select! lp listener)
  (require-listener-ready listener)
  (check/driver
   (pancake_driver_listener_select (driver-loop-handle lp)
                                   (loop-listener-id listener))))

(define (loop-listener-close! lp listener)
  (unless (eq? (loop-listener-lp listener) lp)
    (raise-pancake 'pancake-loop ERR-INVALID-ARGUMENT
                   "listener belongs to another driver loop"))
  (define state-box (loop-listener-state listener))
  (define prior
    (let claim ()
      (define state (unbox state-box))
      (cond
        [(memq state '(closed failed closing)) #f]
        [(box-cas! state-box state 'closing) state]
        [else (claim)])))
  (when prior
    (define close-error #f)
    (with-handlers ([exn? (lambda (e) (set! close-error e))])
      (when (loop-native-live? lp)
        (close-driver-listener! (driver-loop-handle lp) (loop-listener-id listener))))
    (when close-error
      (set-box! state-box prior)
      (raise close-error))
    (when (eq? prior 'pending)
      (set-box! (loop-listener-outcome listener) (listener-closed-exn 'close))
      (semaphore-post (loop-listener-settled listener)))
    (set-box! state-box 'closed)
    ;; Preserve events committed before close, including accepted sessions,
    ;; before retiring this listener's routing entry.
    (define m (driver-loop-host lp))
    (with-host-drain m
      (lambda () (dispatch-events! m lp (pop-events! lp))))
    (hash-remove! (driver-loop-listeners lp) (loop-listener-id listener))
    (async-channel-put (loop-listener-accepts listener) accepts-terminal))
  ;; Preserve only events committed by earlier steps. Running another step
  ;; here would make close itself create unrelated transport progress.
  (loop-listener-accepts listener))

;; A listening server over the loop: this owner owns one driver listener and its
;; unclaimed accept handles. Closing it stops only that listener; the loop,
;; Host, yielded sessions, and sibling listeners remain live. `retire-loop?` is
;; set when a bare `listen` created the loop and Host itself: that server is
;; their only reachable owner, so closing it also retires the loop.
(struct loop-server (lp listener time-travel? retire-loop? closed?))

(define (make-loop-server lp listener time-travel? retire-loop?)
  (loop-server lp listener time-travel? retire-loop? (box #f)))

(define (loop-server-locator s)
  (loop-listener-locator (loop-server-lp s) (loop-server-listener s)))

(define (loop-server-advertise! s locator-uri)
  (loop-listener-advertise! (loop-server-lp s) (loop-server-listener s)
                            locator-uri)
  (loop-listener-select! (loop-server-lp s) (loop-server-listener s)))

;; The next accepted session, already handshaken inside the accepting step.
;; Raises the listener-closed failure every accept surface raises once the
;; loop closes, so a server loop ends the same way byte-fed admission ends.
(define (loop-server-accept s)
  (define lp (loop-server-lp s))
  (when (unbox (loop-server-closed? s))
    (raise-pancake 'accept ERR-CLOSED "listener closed"))
  (define accepts (loop-listener-accepts (loop-server-listener s)))
  (define item (async-channel-get accepts))
  (cond
    [(eq? item accepts-terminal)
     ;; Re-arm the terminal so every sibling accept ends too.
     (async-channel-put accepts accepts-terminal)
     (raise-pancake 'accept ERR-CLOSED "listener closed")]
    [(exn? item)
     (async-channel-put accepts item)
     (raise item)]
    [else (wrap-loop-session lp item (loop-server-time-travel? s))]))

(define (loop-server-host s) (driver-loop-host (loop-server-lp s)))

;; How long a loop close driver may park before stepping again: milliseconds
;; until the nearest pending-work deadline (close grace, session close grace,
;; a dial or listener setup budget), clamped at zero, or -1 when no finite
;; deadline is pending and readiness alone advances the loop. An expiry takes
;; effect only inside a step, so the timer arm of each driver below is what
;; applies it.
(define (loop-step-wait-ms lp)
  (define-values (rc wait-ms)
    (pancake_driver_step_wait_ms (driver-loop-handle lp)))
  (check/driver rc)
  wait-ms)

;; Drive a retirement already committed by the native driver. Racket supplies
;; stepping and projects effects; the driver decides when the last claimed
;; session permits ordinary cancel close. The wait is event-driven: snapshot
;; the host progress event before stepping (so a rival path's step landing
;; between this step and the park still wakes this driver), then park on that
;; snapshot or on the nearest pending-work deadline.
(define (drive-loop-retirement! lp)
  (define m (driver-loop-host lp))
  (let loop ()
    (define gen (host-progress-evt m))
    (define state #f)
    (define wait-ms -1)
    (define fx
      (call-with-host
       m
       (lambda ()
         (define effects (loop-drain! m lp))
         (define-values (rc lifecycle)
           (pancake_driver_lifecycle_state (driver-loop-handle lp)))
         (check/driver rc)
         (set! state lifecycle)
         (unless (lifecycle-closed? lifecycle)
           (set! wait-ms (loop-step-wait-ms lp)))
         effects)))
    (run-drain-effects! m fx)
    ;; A productive pass advanced state a sibling driver may be parked on;
    ;; an idle pass stays silent so parked drivers cannot wake each other in
    ;; an endless idle exchange.
    (when (drain-effects-productive? fx) (host-bump-progress! m))
    (unless (lifecycle-closed? state)
      (if (>= wait-ms 0)
          (sync/timeout (/ wait-ms 1000.0) gen)
          (sync gen))
      (loop)))
  (host-release-after-native-close! m))

(define (run-loop-retirement! lp)
  (with-handlers ([converts-to-broken?
                   (lambda (error) (loop-background-failed! lp error))])
    (drive-loop-retirement! lp)))

;; A bare server owns the Host it created. Commit native retirement once and
;; let the driver preserve every session handle already returned.
(define (driver-loop-retire! lp)
  (define state (driver-loop-state lp))
  (define claimed?
    (let claim ()
      (case (unbox state)
        [(open) (if (box-cas! state 'open 'retiring) #t (claim))]
        [(retiring failed stopping released) #f])))
  (when claimed?
    (call-with-host
     (driver-loop-host lp)
     (lambda ()
       (check/driver (pancake_driver_retire (driver-loop-handle lp)))))
    (void (thread (lambda () (run-loop-retirement! lp))))))

(define (loop-server-close! s)
  (when (box-cas! (loop-server-closed? s) #f #t)
    (define lp (loop-server-lp s))
    (when (loop-running? lp)
      (define accepts (loop-listener-close! lp (loop-server-listener s)))
      ;; The C ABI preserves committed accepts. This server no longer has an
      ;; acceptor, so release every unclaimed handle before publishing terminal
      ;; state; sessions already wrapped live in the Host registry and remain.
      (when accepts
        (let drain ()
          (define item (async-channel-try-get accepts))
          (when item
            (unless (eq? item accepts-terminal)
              (hash-remove! (driver-loop-closed-ptrs lp) (session-key item))
              (loop-session-release! lp item))
            (drain))))
      (when (loop-server-retire-loop? s)
        (driver-loop-retire! lp)))))

;; ── Release (the host.rkt hooks) ─────────────────────────────────────────────

;; Drive the native owner barrier while ordinary loop stepping and event
;; projection remain live. The driver/core decide every transition and
;; outcome; this binding supplies execution and observes completion.
(define (begin-loop-close! lp options)
  (check/driver (pancake_driver_close (driver-loop-handle lp) options)))

;; The wait is event-driven, the same shape as the byte-fed
;; `drive-host-close!`: snapshot the host progress event before stepping,
;; step and drain, then park on that snapshot or on the nearest pending-work
;; deadline from `loop-step-wait-ms`. A wait of -1 means no finite deadline
;; is pending: only loop progress (a readiness-driven step, a verb's kicked
;; drain, an escalation) can advance the barrier, so the driver parks on the
;; progress event alone.
(define (drive-loop-close! lp)
  (define m (driver-loop-host lp))
  (let loop ()
    (define gen (host-progress-evt m))
    (define state #f)
    (define close-code OK)
    (define wait-ms -1)
    (define fx
      (call-with-host
       m
       (lambda ()
         (define effects (loop-drain! m lp))
         (define-values (rc lifecycle)
           (pancake_driver_lifecycle_state (driver-loop-handle lp)))
         (unless (or (= rc OK) (= rc ERR-TIMEOUT)) (check/driver rc))
         (set! close-code rc)
         (set! state lifecycle)
         (unless (lifecycle-closed? lifecycle)
           (set! wait-ms (loop-step-wait-ms lp)))
         effects)))
    (run-drain-effects! m fx)
    (when (drain-effects-productive? fx) (host-bump-progress! m))
    (cond
      [(lifecycle-closed? state) close-code]
      [(>= wait-ms 0) (sync/timeout (/ wait-ms 1000.0) gen) (loop)]
      [else (sync gen) (loop)])))

;; Drive one loop-owned session through the same core policy while the loop
;; remains live. SESSION_CLOSED projection retires the Racket shell; this
;; function only supplies steps and observes the native result beforehand.
(define (begin-loop-session-close! lp c options)
  (check/driver
   (pancake_driver_session_close
    (driver-loop-handle lp) (session-ptr c) options)))

(define (await-loop-session-close! lp c)
  (define m (driver-loop-host lp))
  (let loop ()
    (unless (session-released? c)
      ;; The progress snapshot precedes the step and the released check (the
      ;; pump-until idiom), so a rival path retiring this shell between the
      ;; check and the park still wakes this driver.
      (define gen (host-progress-evt m))
      (define state #f)
      (define close-code OK)
      (define wait-ms -1)
      (define fx
        (call-with-host
         m
         (lambda ()
           (define effects (loop-drain! m lp))
           (define-values (rc lifecycle)
             (pancake_driver_session_lifecycle_state
              (driver-loop-handle lp) (session-ptr c)))
           (unless (or (= rc OK) (= rc ERR-TIMEOUT)) (check/driver rc))
           (set! close-code rc)
           (set! state lifecycle)
           (when (lifecycle-closed? state)
             (set-box! (session-close-result c) close-code))
           (unless (lifecycle-closed? state)
             (set! wait-ms (loop-step-wait-ms lp)))
           effects)))
      (run-drain-effects! m fx)
      (when (drain-effects-productive? fx) (host-bump-progress! m))
      (unless (session-released? c)
        (if (>= wait-ms 0)
            (sync/timeout (/ wait-ms 1000.0) gen)
            (sync gen))
        (loop))))
  (define result (unbox (session-close-result c)))
  (cond
    [(exn? result) (raise result)]
    [(not (= result OK)) (check/driver result)]))

;; The pre-teardown stop the Host release worker runs OUTSIDE the host lock after the
;; native barrier: end Racket-side stepping, join the park thread, and retire
;; listener wrappers whose native owners are already closed. The park thread
;; needs the host lock for its own drain, so joining it under the lock would
;; deadlock.
(define (loop-prestop! lp _orderly?)
  (define state (driver-loop-state lp))
  (define claimed?
    (let claim ()
      (case (unbox state)
      [(open) (if (box-cas! state 'open 'stopping) #t (claim))]
      [(retiring) (if (box-cas! state 'retiring 'stopping) #t (claim))]
      [(failed) (if (box-cas! state 'failed 'stopping) #t (claim))]
      [(stopping released) #f])))
  (when claimed?
    (semaphore-post (driver-loop-stop-sema lp))
    (define t (driver-loop-park-thread lp))
    (cond
      [(and t (eq? t (current-thread)))
       (when (driver-loop-fd lp)
         (unsafe-file-descriptor->semaphore (driver-loop-fd lp) 'remove))]
      [t (thread-wait t)]
      [else (void)])))

;; The native teardown the Host release worker runs in place of
;; `pancake_host_release`, under the host lock, after the sessions closed:
;; release the loop (which frees the wrapped host), then the sidecar
;; endpoint it retained, in that order so no resident call runs against a
;; freed endpoint. The close procedure was captured at adoption, so this
;; path — reachable from the FFI finalizer thread — resolves no module.
(define (loop-native-release! lp)
  (cond
    [(not (loop-native-live? lp)) (values OK #f)]
    [else
     (define-values (code failure)
       (call/driver-failure
        'driver-release
        (lambda (out) (pancake_driver_release (driver-loop-handle lp) out))))
     (when (release-consumed? code)
       (set-box! (driver-loop-state lp) 'released)
       (for ([listener (in-hash-values (driver-loop-listeners lp))])
         (cond
           [(box-cas! (loop-listener-state listener) 'pending 'closed) (void)]
           [(box-cas! (loop-listener-state listener) 'ready 'closed) (void)]
           [else (void)])
         (async-channel-put (loop-listener-accepts listener) accepts-terminal))
       (hash-clear! (driver-loop-listeners lp)))
     (values code failure)]))

;; A loop-owned session's release: through the loop, so the native tier
;; unhooks the wire it is polling. After native teardown the handles are
;; already freed with the loop; the guard keeps a straggling finalizer from
;; touching them.
(define (loop-session-release! lp ptr)
  (when (loop-native-live? lp)
    (check/driver (pancake_driver_session_release (driver-loop-handle lp) ptr))
    (hash-remove! (driver-loop-closed-ptrs lp) (session-key ptr))))

(define (loop-claim-reference-exporter lp reference)
  (define-values (rc ptr)
    (pancake_driver_claim_reference_exporter (driver-loop-handle lp) reference))
  (check/driver rc)
  ptr)

;; A loop-owned host redeems handoffs inside its own steps (ADR-0112), so
;; the exporter session it dialed exists with no wrapper yet; wrap it lazily
;; — `build-session` registers it, so a repeat lookup answers this same
;; object.
(define (loop-wrap-session lp ptr) (wrap-loop-session lp ptr #f))

(set-box! loop-drain-hook loop-drain!)
(set-box! loop-begin-close-hook begin-loop-close!)
(set-box! loop-close-barrier-hook drive-loop-close!)
(set-box! loop-prestop-hook loop-prestop!)
(set-box! loop-native-release-hook loop-native-release!)
(set-box! loop-begin-session-close-hook begin-loop-session-close!)
(set-box! loop-await-session-close-hook await-loop-session-close!)
(set-box! loop-session-release-hook loop-session-release!)
(set-box! loop-claim-reference-exporter-hook loop-claim-reference-exporter)
(set-box! loop-wrap-session-hook loop-wrap-session)
