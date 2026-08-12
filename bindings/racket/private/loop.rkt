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
         "codec.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
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
         "session.rkt")

(provide open-driver-loop
         driver-loop?
         driver-loop-host
         driver-loop-start!
         driver-loop-abort!
         driver-loop-add-provider!
         driver-loop-has-transport?
         loop-listen!
         loop-listener-locator
         loop-listener-advertise!
         loop-listener-select!
         loop-listener-close!
         loop-connect-session
         make-loop-server
         loop-server?
         loop-server-designator
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
;; `dials` maps an admitted dial's ticket to its waiter; `accepts` queues
;; accepted session handles (and the close terminal); `closed-ptrs` records a
;; SESSION_CLOSED handle no wrapper had claimed yet, so a later wrap starts
;; closed instead of parking on a dead wire; `state` is the loop lifetime
;; authority: open, retiring after its last application session, scheduled
;; for Host release, stopping while teardown joins the park thread, or
;; released after the native handle is freed.
(struct driver-loop
  ([handle #:mutable]
   [host #:mutable]
   [carrier #:mutable]
   event-buf
   dials
   accepts
   closed-ptrs
   state
   stop-sema
   [park-thread #:mutable]
   [fd #:mutable]))

(struct loop-dial-waiter (sema result))

;; Wakes every parked accept when the loop closes, so a server iteration ends
;; instead of waiting on a queue nothing will ever feed again.
(define accepts-terminal (gensym 'loop-accepts-closed))

(define (fresh-event-buf)
  (make-PancakeDriverEvent
   0 0 #f
   (make-PancakeHostAction
    0 0 #f
    (make-PancakeArgument 0 0 0 0.0 #f 0 (make-PancakeReference 0) #f 0)
    #f 0)
   #f 0))

;; What a loop step's behavior callbacks read as the arriving deliver context
;; (`current-deliver-session`): enough session shape for the turn bracket —
;; `session-host` for turn-time spawn and `host-defer-turn` — and nothing
;; else. Never registered, never pumped; its transport parks and yields.
(define (make-step-carrier m)
  (session (make-async-connection
            (async-transport (lambda (_frame) (void)) void
                             (lambda (wake-evt) (sync wake-evt) 'woke) void))
           #f m #f
           (pending-writes (make-async-channel) (box 0) (make-semaphore 1) 1)
           (make-semaphore 1) (box #f)))

;; Create the loop and adopt its wrapper host. The seed is the host
;; constructor's 64-byte contract: the durable identity, then a fresh
;; session-key root drawn here, at this binding's entropy boundary
;; (ADR-0097). Both wait budgets must be positive — the loop offers no
;; unbounded wait, which is why the unbounded handshake opt-in stays on the
;; byte-fed dial.
(define (open-driver-loop #:seed [seed #f]
                          #:codec [codec 'syrup]
                          #:captp-version [captp-version 'v1_0]
                          #:features [features 'full]
                          #:wire-buffer-bytes [wire-buffer-bytes DRIVER-DEFAULT-WIRE-BUFFER-BYTES]
                          #:max-pending-opens [max-pending-opens DRIVER-DEFAULT-MAX-PENDING-OPENS]
                          #:handshake-ms [handshake-ms DRIVER-DEFAULT-HANDSHAKE-MS]
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
                 (box 'open) (make-semaphore 0) #f #f))
  ;; Native adoption is the transaction. No Racket Host field changes until
  ;; the call succeeds, so an error leaves the Host byte-fed and live.
  (define options
    (make-PancakeDriverOptions DRIVER-OPTIONS-ABI-VERSION (ctype-sizeof _PancakeDriverOptions)
                               wire-buffer-bytes max-pending-opens
                               handshake-ms settle-ms))
  (define adopted? #f)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (if adopted?
                         (driver-loop-abort! lp)
                         (unless supplied-host (host-release! m)))
                     (raise e))])
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
  (with-handlers ([(lambda (_) #t) void])
    (host-release! (driver-loop-host lp))))

(define (loop-running? lp)
  (memq (unbox (driver-loop-state lp)) '(open retiring)))

(define (loop-native-live? lp)
  (not (eq? (unbox (driver-loop-state lp)) 'released)))

;; ── Transport providers ─────────────────────────────────────────────────────

;; Provider packages are generic to the loop; private implementation tables
;; stay behind the archive ABI.
(define (driver-loop-add-provider! lp package)
  (check/driver (pancake_driver_add_provider (driver-loop-handle lp) package)))

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
;; progress bump every parked pump waits on. While an admitted dial is in
;; flight its budget expiry is visible only inside a step, so the park
;; becomes a 50ms ticker until the dial settles.
(define (park-run lp)
  (define m (driver-loop-host lp))
  (define fd (driver-loop-fd lp))
  (let loop ()
    (when (loop-running? lp)
      (with-handlers ([converts-to-broken? void])
        (drain-host! m))
      (when (loop-running? lp)
        (define sema (unsafe-file-descriptor->semaphore fd 'read))
        (unless sema
          (error 'pancake-loop "the loop readiness fd cannot be registered for polling"))
        (define stop (semaphore-peek-evt (driver-loop-stop-sema lp)))
        (if (zero? (hash-count (driver-loop-dials lp)))
            (sync sema stop)
            (sync/timeout 0.05 sema stop))
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
     (dispatch-events! m lp events)]))

;; Drain `pancake_driver_next_event` until WOULD-BLOCK, consing decoded owned
;; values onto `acc` while each C view is live. The step loop reverses once
;; after the native loop reaches quiescence.
(define (pop-events-onto! lp acc)
  (define ev (driver-loop-event-buf lp))
  (let loop ([acc acc])
    (define rc (pancake_driver_next_event (driver-loop-handle lp) ev))
    (cond
      [(= rc WOULD-BLOCK) acc]
      [else
       (check/driver rc)
       (define kind (PancakeDriverEvent-kind ev))
       (loop (cons (list kind
                         (PancakeDriverEvent-ticket ev)
                         (PancakeDriverEvent-session ev)
                         (and (= kind DRIVER-EVENT-COMPLETION)
                              (host-decode-action! (PancakeDriverEvent-action ev) arg<-c))
                         (and (= kind DRIVER-EVENT-OPEN-FAILED)
                              (bytes->string/utf-8
                               (bytes<-c (PancakeDriverEvent-message ev)
                                         (PancakeDriverEvent-message-len ev))
                               #\uFFFD)))
                   acc))])))

;; Pop without driving, for listener close's preserve-already-committed rule.
(define (pop-events! lp)
  (reverse (pop-events-onto! lp '())))

;; Dispatch drained events under the host lock, returning the post-lock
;; fires: settle listeners and dead-session retirement, exactly the split
;; the byte-fed drain keeps.
(define (dispatch-events! m lp events)
  (define fires
    (for/fold ([fires '()]) ([e (in-list events)])
      (define kind (car e))
      (define ticket (cadr e))
      (define ptr (caddr e))
      (define action (cadddr e))
      (define message (car (cddddr e)))
      (cond
        [(= kind DRIVER-EVENT-OPENED)
         (unless (settle-dial-waiter! lp ticket (cons 'ok ptr))
           (loop-session-release! lp ptr))
         fires]
        [(= kind DRIVER-EVENT-OPEN-FAILED)
         (settle-dial-waiter! lp ticket (cons 'fail message))
         fires]
        [(= kind DRIVER-EVENT-ACCEPTED)
         (define accepts (hash-ref (driver-loop-accepts lp) ticket #f))
         (cond
           [accepts (async-channel-put accepts ptr)]
           [else
            ;; An ACCEPTED handle always has an owner. The native close
            ;; contract makes this unreachable after an orderly listener
            ;; drain; release and fail loudly if routing state regresses.
            (loop-session-release! lp ptr)
            (raise-pancake 'pancake-loop ERR-INTERNAL
                           "accepted session names unknown listener ~a" ticket)])
         fires]
        [(= kind DRIVER-EVENT-SESSION-CLOSED)
         (define c (host-session-for-ptr m ptr))
         (cond
           [c
            ;; The pump's EOF choreography, one tier up: mark teardown first
            ;; — ordered before this wire's FAIL completions, so they
            ;; classify as the typed closed error — then retire the dead
            ;; handle post-lock. The native close already broke the far vows.
            (set-box! (async-connection-closed? (session-async c)) #t)
            (pending-writes-clear! (session-pending-writes c))
            (cons (lambda ()
                    (with-handlers ([(lambda (_) #t) void])
                      (abandon-session! c)))
                  fires)]
           [else
            ;; No wrapper claimed this handle yet (queued on the accept
            ;; channel, or a loop-internal redeem leg). It stays valid until
            ;; released, so record the closure and let a later wrap start
            ;; closed; the loop's release frees stragglers.
            (hash-set! (driver-loop-closed-ptrs lp) (session-key ptr) #t)
            fires])]
        [(= kind DRIVER-EVENT-COMPLETION)
         (append (reverse (settle-completion! m action)) fires)]
        [else
         (raise-pancake 'pancake-loop ERR-INVALID-ARGUMENT
                        "unknown loop event kind ~a" kind)])))
  (drain-effects '() (reverse fires) #f))

;; A COMPLETION carries the byte-fed queue's own SETTLE or FAIL shape; route
;; it through the same vow table. A FAIL whose vow's home session is in
;; teardown classifies as the typed closed error, the loop spelling of the
;; byte-fed breaking window.
(define (settle-completion! m action)
  (host-dispatch-action!
   action
   (hash
    'settle
    (lambda (act) (settle-vow! m (cadr act) (cons 'ok (caddr act))))
    'fail
    (lambda (act)
      (define v (hash-ref (host-vows m) (cadr act) #f))
      (define home (and v (session-vow-session v)))
      (define closing?
        (and home (unbox (async-connection-closed? (session-async home)))))
      (settle-vow! m (cadr act) (cons (if closing? 'closed 'broken) (caddr act))))
    ;; The loop executes transport-shaped actions inside its steps and
    ;; forwards only completions, so every other kind here is a contract
    ;; break worth failing loud on.
    'dial (lambda (_a) (completion-kind-error 'dial))
    'flush (lambda (_a) (completion-kind-error 'flush))
    'close (lambda (_a) (completion-kind-error 'close))
    'need-gift-id (lambda (_a) (completion-kind-error 'need-gift-id))
    'resume (lambda (_a) (completion-kind-error 'resume)))))

(define (completion-kind-error kind)
  (raise-pancake 'pancake-loop ERR-INVALID-ARGUMENT
                 "a loop COMPLETION event carried a ~a action" kind))

(define (settle-dial-waiter! lp ticket outcome)
  (define w (hash-ref (driver-loop-dials lp) ticket #f))
  (hash-remove! (driver-loop-dials lp) ticket)
  (cond
    [w
     (set-box! (loop-dial-waiter-result w) outcome)
     (semaphore-post (loop-dial-waiter-sema w))
     #t]
    [else #f]))

;; ── Dial ─────────────────────────────────────────────────────────────────────

;; Begin a nonblocking dial, kick a step so the handshake starts advancing, and park for
;; the outcome. The loop's handshake budget bounds the whole dial natively,
;; and the park thread's dial ticker guarantees the expiring step runs, so
;; this park always ends. HandshakeTimedOut / WaitTimedOut map to the typed
;; timeout the public dial contract promises.
(define (loop-dial! lp locator-uri)
  (define m (driver-loop-host lp))
  (define w (loop-dial-waiter (make-semaphore 0) (box #f)))
  (with-host-drain m
    (lambda ()
      (define-values (rc ticket)
        (call-with-locator-view
         locator-uri
         (lambda (view)
           (pancake_driver_dial (driver-loop-handle lp) view))))
      (check/driver rc)
      (hash-set! (driver-loop-dials lp) ticket w)
      (drain-host-actions! m)))
  ;; The park thread may be in an unbounded fd park from before this dial
  ;; existed; the loop's one cross-thread verb makes the fd readable so it
  ;; wakes into the bounded dial ticker.
  (check/driver (pancake_driver_wake (driver-loop-handle lp)))
  ;; Co-stepping park: a listener fire may run this dial on the park thread
  ;; itself, and then nobody else would step the handshake forward, so the
  ;; waiter ticks the ordinary drain instead of relying on a sibling.
  (let wait ()
    (unless (sync/timeout 0.05 (loop-dial-waiter-sema w))
      (drain-host! m)
      (wait)))
  (define r (unbox (loop-dial-waiter-result w)))
  (case (car r)
    [(ok) (cdr r)]
    [(fail)
     (define reason (cdr r))
     (if (member reason '("HandshakeTimedOut" "WaitTimedOut"))
         (raise-pancake 'connect ERR-TIMEOUT
                        "the partner did not finish the OCapN handshake within the loop's handshake budget")
         (raise-pancake 'connect ERR-IO "dial failed: ~a" reason))]
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
      (when (hash-ref (driver-loop-closed-ptrs lp) (session-key ptr) #f)
        (hash-remove! (driver-loop-closed-ptrs lp) (session-key ptr))
        (set-box! (async-connection-closed? (session-async c)) #t))
      c)))

;; Dial through the loop and wrap the opened session.
(define (loop-connect-session lp locator-uri)
  (wrap-loop-session lp (loop-dial! lp locator-uri) #f))

;; ── Listen and accept ────────────────────────────────────────────────────────

;; Bind one of the loop's per-transport listeners. The kernel's designator (the bound
;; host:port, an ephemeral port resolved) reads back through the canonical
;; locator; listen policy — wildcard refusal, the
;; advertised address — stays with the public `listen` in `listen.rkt`.
(define (loop-listen! lp transport designator)
  (define tb (string->bytes/utf-8 transport))
  (define db (string->bytes/utf-8 designator))
  (define-values (rc listener)
    (pancake_driver_listen (driver-loop-handle lp)
                           (pin-immobile tb) (bytes-length tb)
                           (pin-immobile db) (bytes-length db)))
  (check/driver rc)
  (hash-set! (driver-loop-accepts lp) listener (make-async-channel))
  listener)

(define (loop-listener-locator lp listener)
  (define view (make-PancakeLocatorView 0 0 #f 0 #f 0 #f 0 0))
  (define rc
    (pancake_driver_listener_locator (driver-loop-handle lp) listener view))
  (check/driver rc)
  (clone-locator-view view))

(define (loop-listener-advertise! lp listener locator-uri)
  (call-with-locator-view
   locator-uri
   (lambda (view)
     (check/driver
      (pancake_driver_listener_advertise
       (driver-loop-handle lp) listener view)))))

(define (loop-listener-select! lp listener)
  (check/driver
   (pancake_driver_listener_select (driver-loop-handle lp) listener)))

(define (loop-listener-close! lp listener)
  (check/driver
   (pancake_driver_listener_close (driver-loop-handle lp) listener))
  ;; Preserve only events committed by earlier steps. Running another step
  ;; here would make close itself create unrelated transport progress.
  (define m (driver-loop-host lp))
  (with-host-drain m
    (lambda () (dispatch-events! m lp (pop-events! lp))))
  (define accepts (hash-ref (driver-loop-accepts lp) listener #f))
  (when accepts (async-channel-put accepts accepts-terminal))
  (hash-remove! (driver-loop-accepts lp) listener)
  accepts)

;; A listening server over the loop: this owner owns one driver listener and its
;; unclaimed accept handles. Closing it stops only that listener; the loop,
;; Host, yielded sessions, and sibling listeners remain live.
(struct loop-server (lp listener designator time-travel? owns-host? closed?))

(define (make-loop-server lp listener designator time-travel? owns-host?)
  (loop-server lp listener designator time-travel? owns-host? (box #f)))

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
    (raise (exn:fail:network "listener closed" (current-continuation-marks))))
  (define accepts (hash-ref (driver-loop-accepts lp) (loop-server-listener s)))
  (define item (async-channel-get accepts))
  (cond
    [(eq? item accepts-terminal)
     ;; Re-arm the terminal so every sibling accept ends too.
     (async-channel-put accepts accepts-terminal)
     (raise (exn:fail:network "listener closed" (current-continuation-marks)))]
    [else (wrap-loop-session lp item (loop-server-time-travel? s))]))

(define (loop-server-host s) (driver-loop-host (loop-server-lp s)))

;; A bare server owns the Host it created. Listener close seals admission now;
;; the Host and loop retire only after the authoritative Host session registry
;; becomes empty, so yielded sessions remain application-owned.
(define (driver-loop-retire-when-idle! lp)
  (define state (driver-loop-state lp))
  (let claim ()
    (case (unbox state)
      [(open) (unless (box-cas! state 'open 'retiring) (claim))]
      [(retiring retirement-scheduled stopping released) (void)]))
  (when (and (eq? (unbox state) 'retiring)
             (zero? (hash-count (host-sessions (driver-loop-host lp)))))
    (host-release! (driver-loop-host lp))))

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
      (when (loop-server-owns-host? s)
        (driver-loop-retire-when-idle! lp)))))

;; ── Release (the host.rkt hooks) ─────────────────────────────────────────────

;; The pre-teardown stop `host-release!` runs OUTSIDE the host lock: end
;; Racket-side stepping, fail every parked dial and accept, and join the park
;; thread — which needs the host lock for its own drain, so joining it under
;; the lock would deadlock. Fired from the park thread itself (a listener
;; closing the host inside a drain's post-lock fires), it skips the join and
;; deregisters the fd here, while the thread is running this code rather
;; than parked on it.
(define (loop-prestop! lp)
  (define state (driver-loop-state lp))
  (define claimed?
    (let claim ()
      (case (unbox state)
        [(open) (if (box-cas! state 'open 'stopping) #t (claim))]
        [(retiring) (if (box-cas! state 'retiring 'stopping) #t (claim))]
        [(retirement-scheduled)
         (if (box-cas! state 'retirement-scheduled 'stopping) #t (claim))]
        [(stopping released) #f])))
  (when claimed?
    (semaphore-post (driver-loop-stop-sema lp))
    (define t (driver-loop-park-thread lp))
    (cond
      [(and t (eq? t (current-thread)))
       (when (driver-loop-fd lp)
         (unsafe-file-descriptor->semaphore (driver-loop-fd lp) 'remove))]
      [t (thread-wait t)]
      [else (void)])
    (for ([(_ticket w) (in-hash (driver-loop-dials lp))])
      (set-box! (loop-dial-waiter-result w) (cons 'closed #f))
      (semaphore-post (loop-dial-waiter-sema w)))
    (hash-clear! (driver-loop-dials lp))
    (for ([accepts (in-hash-values (driver-loop-accepts lp))])
      (async-channel-put accepts accepts-terminal))))

;; The native teardown `host-release!` runs in place of
;; `pancake_host_release`, under the host lock, after the sessions closed:
;; release the loop (which frees the wrapped host), then the sidecar
;; endpoint it retained, in that order so no resident call runs against a
;; freed endpoint. The close procedure was captured at adoption, so this
;; path — reachable from the FFI finalizer thread — resolves no module.
(define (loop-native-release! lp)
  (when (loop-native-live? lp)
    (check/driver (pancake_driver_release (driver-loop-handle lp)))
    (set-box! (driver-loop-state lp) 'released)))

;; A loop-owned session's release: through the loop, so the native tier
;; unhooks the wire it is polling. After native teardown the handles are
;; already freed with the loop; the guard keeps a straggling finalizer from
;; touching them.
(define (loop-session-release! lp ptr)
  (when (loop-native-live? lp)
    (hash-remove! (driver-loop-closed-ptrs lp) (session-key ptr))
    (check/driver (pancake_driver_session_release (driver-loop-handle lp) ptr))
    ;; Session unregister precedes this hook. A retiring loop crosses to Host
    ;; teardown exactly once, on a fresh green thread so it joins the park
    ;; thread only after the current Host drain releases its lock.
    (when (and (eq? (unbox (driver-loop-state lp)) 'retiring)
               (zero? (hash-count (host-sessions (driver-loop-host lp))))
               (box-cas! (driver-loop-state lp) 'retiring 'retirement-scheduled))
      (thread (lambda () (host-release! (driver-loop-host lp)))))))

;; A loop-owned host redeems handoffs inside its own steps (ADR-0112), so
;; the exporter session it dialed exists with no wrapper yet; wrap it lazily
;; — `build-session` registers it, so a repeat lookup answers this same
;; object.
(define (loop-wrap-session lp ptr) (wrap-loop-session lp ptr #f))

(set-box! loop-drain-hook loop-drain!)
(set-box! loop-prestop-hook loop-prestop!)
(set-box! loop-native-release-hook loop-native-release!)
(set-box! loop-session-release-hook loop-session-release!)
(set-box! loop-wrap-session-hook loop-wrap-session)
