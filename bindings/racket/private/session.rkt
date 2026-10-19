#lang racket/base
;; Internal: the CapTP `session` surface over the byte-fed host
;; (libglowcap_host, ADR-0022 / ADR-0011). It owns the application verbs and
;; serve path, construction/abandon, and the core-selected terminal effect.
;; `session/state.rkt`, `session/identity.rkt`,
;; `session/establish.rkt`, and `session/close.rkt` own their named siblings.
;; Dial/listen orchestration lives in `dial.rkt` and `tcp-listen.rkt`; pump owns
;; the byte path and shared drain choreography; action, promise, and
;; bounded-write-queue subjects live in their named private modules. This module
;; composes those owners into the Session API.
;;
;; THE ACTION DRAIN. After any top-level host verb, the action queue drains
;; until dry (the one loop rule): a NEED_GIFT_ID draws 32 random bytes on the
;; spot, a FLUSH parks the named session's encoded outbound on its
;; pending-writes FIFO (via `drain-outbound!` in `pump.rkt`), and a DIAL parks
;; the executor among the drain's fires. The pops run under the host's
;; reentrant lock (`call-with-host`), so several green threads can share one
;; host (a server's accepted sessions, a gifter's exporter dial) while the C
;; host sees one caller at a time; everything that can block (socket writes,
;; dial executors, listener fires) runs after the lock releases. Reads happen
;; outside the lock too: `pump-until` (in `pump.rkt`) makes one thread the
;; session's reader (the `async-connection` reader gate), parks drain effects
;; until that gate clears, and parks every other pump on the host's progress
;; event. So a settle another session's feed recorded wakes a pump parked on
;; its own quiet socket without sharing the reader window with a write or fire.

(require ffi/unsafe
         "constants.rkt"
         "abi-value.rkt"
         "ffi-ocapn.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "value.rkt"
         "vat.rkt"
         "async.rkt"
         "pending-writes.rkt"
         (combine-in "host.rkt" "host/state.rkt")
         "trace.rkt"
         "trampoline.rkt"
         "pump.rkt"
         "action.rkt"
         "promise.rkt"
         "gc.rkt"
         "locator.rkt"
         "session/state.rkt")

(provide (all-defined-out)
         (all-from-out "pending-writes.rkt")
         ;; Feed-refusal `last_abort` lives in pump; re-export for dogfood that
         ;; requires this module for CapTP verbs. The handshake bound lives
         ;; there too, beside the deadline machinery dial and accept share;
         ;; re-export it for the public barrel.
         session-last-abort
         HANDSHAKE-TIMEOUT-MS)

;; A broken byte stream retires only its Session. This may run from an
;; unrelated Host action drain, so it contains teardown failures on the same
;; Session instead of aborting the drain or recursively starting core close.
(define (retire-session-wire-failure! c)
  (set-box! (session-transport-lost? c) #t)
  (set-box! (session-closing-state c) #t)
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (record-session-wire-failure! c error)
                     (void))])
    (handle-session-eof! c)))

;; Distributed GC (`session-with-gc!` / `track-argument!` / `drain-gc!`) lives in
;; `private/gc.rkt`. Feed-refusal / `session-last-abort` lives in `private/pump.rkt`.

;; ── The action drain ──────────────────────────────────────────────────────────
;; Decode + execute (`drain-host-actions!`) live in `private/action.rkt`.
;; Post-lock writes, fires, host drain brackets, feed / flush / EOF, and
;; `pump-until` live in `private/pump.rkt`.

;; Far-send / far-tell mint (`session-far-send`) lives in `promise.rkt`.

;; Break every far vow still parked on `c`, firing each listener with
;; `message` (or the partner's retained abort diagnostic when one arrived).
;; The vat-level `break-far-vows!` reaches here through the installed far half.
;; The FFI lives in pump; this wrapper owns the session-effect drain.
(define (session-break-far-vows! c message)
  (with-session-drain c
    (lambda ()
      (break-far-vows-bytes! c (string->bytes/utf-8 message)))))

;; ── Construction: build, establish, dial, listen, accept ─────────────────────

;; Wrap a freshly minted Host session in a `session`: build the pump
;; state and the vat, install the vat's far half, and join the host's registry
;; so a FLUSH action and a routed send can find it. The single place a
;; `session` is born, so every path shares the same wiring.
(define (build-session m ptr transport time-travel?)
  (define ac (make-async-connection transport))
  (define v (make-vat #:time-travel? time-travel?))
  (define c (session ac v m ptr
                     (make-pending-writes)
                     (make-semaphore 1)
                     (make-GlowcapManagedFrame #f 0 0 #f (make-vector 8 0))
                     (make-bytes HOST-OUTBOUND-PREFIX-CAP)
                     (box #f)
                     (box OK)
                     (box #f)
                     (box #f)
                     (box #f)
                     (box #f)))
  (set-box! (async-connection-session ac) c)
  (vat-install-far!
   v
   (far-ops (lambda (ref method args answer?) (session-far-send c ref method args answer?))
            (lambda (a-vow listener) (session-vow-listen! a-vow listener))
            (lambda (message) (session-break-far-vows! c message))))
  (host-register-session! m ptr c)
  c)

;; Retire the connection from the host and free the C handle: the core settles
;; parked far vows during release, stranded sibling withdraws fail closed, and
;; the queued teardown effects drain.
(define (abandon-session! c)
  (define m (session-host c))
  (define ac (session-async c))
  (set-box! (async-connection-closed? ac) #t)
  (pending-writes-clear! (session-pending-writes c))
  ;; The handle must see exactly one release: the mid-turn arm parks an
  ;; unconditional release closure, so a second abandon (two mid-turn closes
  ;; coalesced into one feed, or a repeated `session-close!`) would park a
  ;; double free without this guard. The Python/TS/Rust sessions carry the
  ;; same released? early-out.
  (unless (or (session-released? c) (unbox (session-release-pending? c)))
    (define ptr (session-ptr c))
    (define (commit-release!)
      (with-handlers ([exn? (lambda (e)
                              (set-box! (session-release-pending? c) #f)
                              (raise e))])
        (ffi-session-release! m ptr)
        (set-box! (async-connection-released? ac) #t)
        (set-box! (session-release-pending? c) #f)
        (host-unregister-session! m ptr)
        (host-bump-progress! m)))
    (set-box! (session-release-pending? c) #t)
    (cond
      [(inside-turn?)
       ;; Mid-turn: park the complete release commit. Nested
       ;; `with-session-drain` would re-enter the feed's drain under the
       ;; trampoline latch and hang; the enclosing feed drains the park and
       ;; FAIL completions after the trampoline returns (Python/TS parity).
       (host-park-release! m commit-release!)]
      [else
       ;; The abandoned connection's own parked frames die with it, but the
       ;; drain may flush a *different, healthy* connection (a sibling withdraw
       ;; failing closed), so the touched list is still written after the lock
       ;; releases. The core has already classified any queued FAIL completion.
       (with-session-drain c
         (lambda ()
           (commit-release!)))])))

(define (session-flush! c)
  (define m (session-host c))
  (unless (inside-turn?)
    (with-handlers ([(lambda (_) #t)
                     (lambda (error)
                       (record-session-outbound-failure! c error)
                       (retire-session-wire-failure! c)
                       (raise-session-wire-failure! c))])
      (with-host-drain m
        (lambda ()
          ;; This session is flushed whether or not an action named it, so it
          ;; is merged into the drained effects' touched list.
          (define drained (drain-host-actions! m))
          (drain-outbound! c)
          (define touched (drain-effects-touched drained))
          (drain-effects (if (memq c touched) touched (cons c touched))
                         (drain-effects-fires drained)
                         (drain-effects-resume drained)
                         (drain-effects-popped? drained)))))
    (raise-session-wire-failure! c)))

(define (session-close-code-error result)
  (and (not (= result OK))
       (exn:fail:glowcap
        (if (= result ERR-TIMEOUT)
            "session-close!: finish close exhausted its grace period"
            (format "session-close!: session close failed with glowcap error ~a" result))
        (current-continuation-marks) result #f #f #f #f 0)))

(define (raise-session-terminal-failure! c)
  (raise-session-wire-failure! c)
  (define result (unbox (session-close-result c)))
  (cond
    [(exn? result) (raise result)]
    [(not (= result OK))
     (define error (session-close-code-error result))
     (when error
       (set-box! (session-close-result c) error)
       (raise error))]))

;; Execute the terminal effect selected by the core. This is deliberately
;; separate from `session-close!`: action dispatch closes the transport and
;; releases projection state, but never chooses close policy.
(define (finish-session-close! c result)
  (define close-error (session-close-code-error result))
  (set-box! (session-close-result c) (or close-error result))
  (when close-error (record-session-wire-failure! c close-error))
  (close-session-transport! c)
  (with-handlers ([(lambda (_) #t)
                   (lambda (error)
                     (record-session-wire-failure! c error)
                     (void))])
    (abandon-session! c)))

;; ── Spawning, publishing, and the proxy verbs ─────────────────────────────────

;; Spawn/publish hosting mint (`register-hosted-actor!`) lives in
;; `trampoline.rkt`.

;; Spawn a local actor and return its opaque Host capability to hand a partner.
;; `(session-spawn c ^name arg …)` constructs like `spawn`. Wire export
;; positions stay inside glowcap. Callable from inside a served turn (a
;; factory's `create` minting the task it replies with).
(define (session-spawn c constructor . args)
  (define actor (with-vat (session-vat c) (apply spawn constructor args)))
  (register-hosted-actor! c actor))

;; Publish an actor fetchable by name (a swiss-number). Returns its opaque Host
;; capability.
(define (session-publish c name constructor . args)
  (define actor (with-vat (session-vat c) (apply spawn constructor args)))
  (register-hosted-actor! c actor #:name name))

;; The Host capability for the object published under `name`, or
;; #f when nothing is published there.
;;
;; `session-publish` returns its own capability, so this is for the other
;; publisher: `host-publish` hosts one actor under a Host-wide alias
;; and returns nothing. Reading its Host identity lazily projects it onto this
;; session so an application can pass it as an ordinary capability argument.
;;
;; A Host publication is a bare trampoline closure here rather than a vat actor, so the
;; result is for handing to a partner: unlike a `session-spawn` capability, a
;; local send to it is not composed in Racket.
(define (session-published-ref c name)
  (define m (session-host c))
  (define nb (string->bytes/utf-8 name))
  (define-values (rc capability)
    (call-with-host m
      (lambda ()
        (glowcap_host_session_published_ref
         (session-ptr c) (pin-immobile nb) (bytes-length nb)))))
  (cond
    [(= rc ERR-NOT-FOUND) #f]
    [else (check/host rc) (make-ref/internal (GlowcapReference-id capability))]))

;; Wrap `target` in a revocable caretaker (ADR-0016). Returns the proxy capability
;; to hand a partner; every call through it forwards to `target` until
;; `session-revoke!`, after which each breaks with "Revoked". `target` may be a
;; capability imported over the wire (the proxy forwards transparently), so this
;; hands out a revocable view of authority you do not own locally.
(define (session-caretaker c target)
  (caretaker-proxy c target))

;; Wrap `target` in an attenuator (ADR-0016): a proxy that forwards only the
;; calls whose verb is in `verbs` (strings or symbols) and breaks every other
;; with "Attenuated". Returns the proxy near capability to hand a partner. The
;; proxy is a plain spawned actor.
(define (session-attenuate c target verbs)
  (attenuate-proxy c target verbs))

;; Revoke a caretaker `proxy` (the near capability `session-caretaker` returned):
;; every later call through it breaks with "Revoked". Idempotent.
(define (session-revoke! c proxy)
  (revoke-caretaker! c proxy))

;; ── The application verbs ─────────────────────────────────────────────────────

;; Eventual-send `verb` to `target` and drive the session until the reply
;; settles, returning the fulfilled value, the request/reply half whose
;; fire-and-forget sibling is `session-tell`. A reference this session spawned
;; resolves in process; a partner's ref goes out on the wire, and a redeemed
;; handoff token routes to the exporter session that hosts it. A broken
;; reply raises a typed `exn:fail:glowcap` carrying GLOWCAP_ERR_BROKEN,
;; as the Python and Rust `send`s fail. Single-threaded: it pumps events
;; itself, matching the rest of the Racket binding. The local arm is
;; `session-send-local` in `trampoline.rkt`.
;; Listen on a far capability this session holds (CapTP op:listen): the
;; returned vow settles with the listen notification, which may be any value,
;; not only a capability. In 1.0, the target may be a far promise or live far
;; object; in glowcap-next, the target must be a promise. A re-gifted promise
;; routes to its exporter session transparently.
(define (session-listen c target)
  (issue-through-handle
   c
   (lambda ()
     (guard-open 'session-listen c)
     (drain-gc! c)
     (listen-far c target))))

(define (session-send c target verb . args)
  (guard-open 'session-send c)
  (drain-gc! c) ; flush any imports reclaimed since the last session op
  (dispatch-send c target verb args))

;; Eventual-send `verb` to `target`, drive the session to the reply as
;; `session-send` does, and also hand back the direct session that reply lives
;; on: `(values reply via)`.
;;
;; When `target` answers with a three-party handoff give (a room's `introduce`
;; naming another member, say), this host redeems it by dialing the exporter,
;; and the reply settles as a capability hosted on that fresh direct
;; session. Its byte connection is otherwise internal to the binding. `via` is
;; the application-facing session, so the caller can spawn or publish its own
;; objects in the very CapTP conversation the redeemed capability lives in.
;; That is the one place a capability handed back to the exporter is valid: an
;; OCapN near export names a position in one specific session, so an inbox
;; spawned on the introducing session means nothing to the exporter that
;; receives it.
;;
;; `via` is #f whenever no such exporter session is in play: the reply is not a live
;; capability at all, or it is an ordinary far reply from `target` itself, or
;; its exporter session has already gone. `(or via c)` is then the session
;; to work on, and the caller needs no separate case for the two.
;;
;; The exporter is resolved from the reply's own route rather than from
;; whichever dial this host finished most recently. So it stays exact with
;; several introductions in flight at once, and a reply whose exporter an
;; earlier redeem already dialed resolves to that live session with no second
;; session opened.
(define (session-send-redeeming c target verb . args)
  (guard-open 'session-send-redeeming c)
  (drain-gc! c) ; flush any imports reclaimed since the last session op
  (define reply (dispatch-send c target verb args))
  (define home (and (ref? reply) (host-exporter-for (session-host c) reply)))
  (values reply (and home (not (eq? home c)) home)))

;; Eventual-send `verb` to `target` and return its vow WITHOUT driving the
;; session to a reply. It is the non-blocking half of `session-send` and the seam
;; for promise pipelining (ADR-0003). The returned vow is itself a valid
;; `target` for a later `session-send`/`session-send-promise`/`session-tell`, so a
;; dependent call rides a `desc:answer` deliver the partner queues until the
;; answer settles; a `create -> use` chain then costs one round trip.
;; Each send schedules progress before returning; settling the tail observes the
;; result rather than making an otherwise-idle chain move. Use `session-tell`
;; for a dependent delivery whose answer is not needed.
;; A target belongs to the Host that minted it; another Host refuses it before
;; interpreting the Host-local vow number.
;; A reference this session spawned resolves in process.
;; A send this session could never issue (the session is closed, the target is
;; a spent capability, an argument will not marshal) comes back as a handle
;; that reports the failure, not as a raise. `session-send-promise` returns
;; before the answer settles so a caller can pipeline at it, so its failure has
;; to travel the same way its answer does: a caller who wraps the settle in a
;; handler and gets the failure at the call site instead never sees it.
(define (session-send-promise c target verb . args)
  (issue-through-handle
   c
   (lambda ()
     (guard-open 'session-send-promise c)
     (dispatch-send-promise c target verb args))))

;; Drive the connection until `a-vow` settles, returning its fulfilled value,
;; the awaiting half of `session-send-promise` / `session-index` / `session-untag`. A
;; broken vow raises a typed `exn:fail:glowcap` (GLOWCAP_ERR_BROKEN), as
;; `session-send` does. A local vow settles in `drive`; a far vow settles on a wire reply,
;; or immediately when the resolution already arrived while a sibling
;; projection pumped the loop. Single-threaded: it pumps events itself, like
;; the rest of the binding.
(define (session-await c a-vow)
  (cond
    [(session-vow? a-vow) (await-vow c a-vow 'session-await "the vow")]
    [(local-vow? a-vow) (await-local-vow c a-vow 'session-await "the vow")]
    [else
     (raise-glowcap 'session-await ERR-INVALID-ARGUMENT "not a vow: ~a" a-vow)]))

;; Fetch a partner's published capability by name, returning the far
;; reference. The canonical fetch lives in the library: one call registers the
;; bootstrap import, allocates the answer, and queues the deliver; the host
;; enrolls the fulfilled capability under a node-unique token (ADR-0026)
;; before the completion fires, so two capabilities fetched at the same wire
;; position on different connections never collide, and a return re-gifts the
;; right home. A partner break raises a typed glowcap failure
;; (GLOWCAP_ERR_BROKEN); a fetch that fulfills with anything but a capability
;; raises a typed unsupported-value failure, the same code the Python binding
;; uses for the same shape. The shared mint→await→classify body is
;; `blocking-fetch` in `promise.rkt`.
(define (session-fetch c name)
  (guard-open 'session-fetch c)
  (drain-gc! c) ; flush any imports reclaimed since the last session op
  (define nb (string->bytes/utf-8 name))
  (blocking-fetch c 'session-fetch "fetch" name
                  (lambda ()
                    (glowcap_host_session_fetch (session-ptr c) (pin-immobile nb)
                                                (bytes-length nb)))
                  #:track-gc? #t))

;; Enliven a sturdyref against this session (ADR-0007): bring the durable
;; `(peer, swissnum)` to life as a live capability. The host verifies the full
;; locator against this session before consulting its dedup cache. A repeat enliven
;; of the same swissnum on this session short-circuits with no wire traffic
;; (its SETTLE completion is queued before the minting call returns). The
;; session must already be open to the sturdyref's peer; this session-level
;; call never dials. A partner break raises a typed
;; GLOWCAP_ERR_BROKEN; a fulfill that is not a capability raises the typed
;; unsupported-value failure, matching `session-fetch` and the other bindings.
(define (session-enliven c sturdyref)
  (guard-open 'session-enliven c)
  (define sturdyref-bytes (string->bytes/utf-8 sturdyref))
  (blocking-fetch c 'session-enliven "enliven" sturdyref
                  (lambda ()
                    (glowcap_host_session_enliven (session-ptr c) (pin-immobile sturdyref-bytes)
                                               (bytes-length sturdyref-bytes)))
                  #:track-gc? #t))

;; Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and no
;; reply comes back, so a notification or broadcast costs one deliver. A
;; self-spawned target runs its turn in-process (like `session-send`); a far one
;; flushes the deliver to the wire.
;; Annotate this session for the live trace: the application states
;; which partner it carries (a chat nick), a claim about naming
;; carried beside the protocol facts. Fire-and-forget like every
;; trace emit.
(define (session-annotate! c #:label label)
  (define m (session-host c))
  (call-with-host
   m
   (lambda ()
     (guard-open 'session-annotate! c)
     (trace-annotate-session! m (session-ptr c) label))))

(define (session-tell c target verb . args)
  (guard-open 'session-tell c)
  (dispatch-tell c target verb args))

;; Drive inbound frames into the host until the connection closes: hosted
;; actors run, far vows settle, and the host's actions execute, all inside the
;; pump. When the wire is gone the pump has already broken every far vow still
;; awaiting a reply (with the partner's retained abort diagnostic when one
;; arrived), the same disconnect guarantee the Deno and Python connections give.
;; A mid-serve failure (a feed refusal, a partner protocol violation) must close
;; the transport before the error escapes: otherwise the partner's blocking
;; `session-send` parks forever on a half-open TCP socket. The Python serve
;; loop's `finally` closes for the same reason. A break is not a failure: the
;; blocking read consumed nothing, so the interrupted serve escapes as the
;; break, the session stays live, and a later `session-serve` resumes it.
(define (session-serve c)
  ;; A loop-backed session's inbound is held until its embedder serves; the
  ;; hook announces readiness (a no-op for byte-fed connections).
  ((unbox (async-connection-serve-hook (session-async c))))
  (set-box! (async-connection-serve-hook (session-async c)) void)
  (drain-gc! c)
  ;; A break is the operator interrupting this serving thread, not the wire
  ;; failing: it escapes as itself and the session stays live for a later
  ;; serve, as the vat's convert-to-broken handlers already promise.
  (with-handlers ([(lambda (raised) (not (exn:break? raised)))
                   (lambda (e)
                     (record-session-wire-failure! c e)
                     (retire-session-wire-failure! c)
                     (raise-session-wire-failure! c))])
    (pump-until c
                (lambda () (and (session-closed? c) 'closed))
                'session-serve)
    (raise-session-terminal-failure! c)
    (void)))

;; ── Host-level select-or-dial capability lookup (ADR-0007) ───────────────────
(define (await-host-capability m v who subject)
  (dynamic-wind
    void
    (lambda ()
      (with-host-drain m (lambda () (drain-host-actions! m)))
      (let loop ()
        (define s (session-vow-state v))
        (cond
          [(eq? s 'pending)
           (define gen (host-progress-evt m))
           (when (eq? (session-vow-state v) 'pending) (sync gen))
           (loop)]
          [(eq? (car s) 'ok)
           (define val (cdr s))
           (unless (ref? val)
             (raise-glowcap who ERR-UNSUPPORTED-VALUE
                            "~a did not resolve to a capability: ~a" subject val))
           val]
          [else
           (raise-glowcap who ERR-BROKEN "~a broke: ~a" subject (cdr s))])))
    (lambda () (release-vow-from-host! m v))))

;; Enliven a complete sturdyref against the host: select a live session this
;; host already dialed to the sturdyref's peer, or stage a dial and settle
;; over the opened session. The blocking wait is host-scoped: the vow
;; belongs to no session (its row's home is #f, and no session's teardown
;; sweeps it), the initial drain runs a staged dial in this thread, the
;; dialed exporter serves itself on its own thread (`run-dial!`), and this
;; thread parks on host progress until the settle lands. The dial executor's
;; failure handler breaks the vow, so the wait always ends. Every binding's
;; `glowcap_host_enliven` contract: the full sturdyref verifies before wire
;; traffic, and a session-scoped repeat rides `session-enliven`'s cache.
(define (host-enliven m sturdyref
                      #:captp-version [captp-version #f]
                      #:connector [connector #f])
  (when (unbox (host-released? m))
    (raise-glowcap 'host-enliven ERR-CLOSED "host released"))
  (define version-id (and captp-version (captp-version-id captp-version)))
  (when connector (host-register-connector! m connector))
  (define sturdyref-bytes (string->bytes/utf-8 sturdyref))
  (define v
    (call-with-host m
      (lambda ()
        (define-values (rc id)
          (if captp-version
              (glowcap_host_enliven_for_version
               (host-ptr m) version-id
               (pin-immobile sturdyref-bytes) (bytes-length sturdyref-bytes))
              (glowcap_host_enliven
               (host-ptr m) (pin-immobile sturdyref-bytes)
               (bytes-length sturdyref-bytes))))
        (check/host rc)
        (adopt-minted-vow! m #f id #f #f))))
  (await-host-capability m v 'host-enliven (format "enliven ~s" sturdyref)))

;; Fetch a named publication at a typed locator. The Host's configured profile
;; owns version, codec, route admission, and physical dial selection.
(define (host-fetch-at m locator name #:connector [connector #f])
  (when (unbox (host-released? m))
    (raise-glowcap 'host-fetch-at ERR-CLOSED "host released"))
  (when connector (host-register-connector! m connector))
  (define name-bytes (string->bytes/utf-8 name))
  (define v
    (call-with-locator-view
     locator
     (lambda (view)
       (call-with-host m
         (lambda ()
           (define-values (rc id)
             (glowcap_host_fetch_at
              (host-ptr m) view (pin-immobile name-bytes) (bytes-length name-bytes)))
           (check/host rc)
           (adopt-minted-vow! m #f id #f #f))))))
  (await-host-capability m v 'host-fetch-at (format "publication ~s" name)))

;; ── Off-turn settlement: the resolver pair ────────────────────────────────────
;; A behavior atomically defers with `host-defer-turn`, parks the resolver for
;; whatever completes the work, and returns; the completion settles it later with
;; `resolver-fulfill!` / `resolver-break!` as its own top-level event. One
;; settle per resolver (a second refuses), and a deferred settle carries
;; plain data only: a value that names a capability is refused, and an answer
;; that carries authority forwards to a send instead.

(struct resolver (host id))

;; Atomically defer the current turn and return its settle authority.
(define (host-defer-turn m)
  (define t (current-turn))
  (unless t
    (error 'host-defer-turn "a turn verb: call it inside a behavior"))
  (unless (eq? (turn-context-host t) m)
    (error 'host-defer-turn "the turn belongs to another host"))
  (call-with-host m
    (lambda ()
      (define-values (rc resolver-id) (glowcap_host_turn_defer (turn-context-turn t)))
      (check/host rc)
      (resolver m resolver-id))))

;; Calls retain one-shot settlement custody; tells create no resolver.
(define (host-defer-turn-if-answer m)
  (define t (current-turn))
  (unless (and t (eq? (turn-context-host t) m))
    (error 'host-defer-turn-if-answer "call it inside a behavior of this host"))
  (call-with-host m
    (lambda ()
      (define-values (rc resolver-id) (glowcap_host_turn_defer_if_answer (turn-context-turn t)))
      (check/host rc)
      (and (not (zero? resolver-id)) (resolver m resolver-id)))))

;; Settle the deferred answer fulfilled with the capability-free `value`.
(define (resolver-fulfill! r value)
  (define m (resolver-host r))
  (with-host-drain m
    (lambda ()
      (define keep (box '()))
      (define-values (aptr acnt) (args->c (list value) keep))
      (void acnt)
      ;; args->c hands back a raw block; the generated signature wants the
      ;; tagged single-struct pointer.
      (check/host (glowcap_host_resolver_fulfill
                   (host-ptr m) (resolver-id r)
                   (cast aptr _pointer _GlowcapArgument-pointer)))
      ;; Buffers nested inside `aptr` are reachable only through `keep`, whose
      ;; raw addresses the collector cannot see; keep them live past the call.
      (void/reference-sink keep)
      (drain-host-actions! m))))

;; Settle the deferred answer broken with the worker's own words.
(define (resolver-break! r reason)
  (define m (resolver-host r))
  (with-host-drain m
    (lambda ()
      (define rb (string->bytes/utf-8 reason))
      (check/host (glowcap_host_resolver_break (host-ptr m) (resolver-id r)
                                               (pin-immobile rb) (bytes-length rb)))
      (drain-host-actions! m))))

;; Relinquish deferred work; prior settlement or session retirement is complete
;; cleanup. Strict manual settlement remains resolver-fulfill! / resolver-break!.
(define (resolver-abandon! r reason)
  (define m (resolver-host r))
  (with-host-drain m
    (lambda ()
      (define rb (string->bytes/utf-8 reason))
      (check/host (glowcap_host_resolver_abandon (host-ptr m) (resolver-id r)
                                               (pin-immobile rb) (bytes-length rb)))
      (drain-host-actions! m))))
