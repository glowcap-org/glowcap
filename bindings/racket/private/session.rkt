#lang racket/base
;; Internal: the CapTP `session` surface over the byte-fed host
;; (libpancake_driver, ADR-0072 / ADR-0079). It owns the `session` struct and
;; every `session-*` application verb (`session-fetch`, `session-send`,
;; `session-tell`, `session-serve`, …), plus mint/handshake (`establish-*`).
;; The dial executor (plan + channel open + `connect`) lives in
;; `private/dial.rkt`. Server/`listen`/`accept` live in `private/listen.rkt`.
;; The host action switch (`drain-host-actions!` / `host-next-action!`) lives
;; in `private/action.rkt`. Far vows (`session-vow` / `session-index` /
;; `session-untag` / settle), far-send mint (`session-far-send`), and the
;; shared fetch wait live in `private/promise.rkt`. The conn byte path
;; — handshake, read raw bytes, `pancake_host_session_feed_bytes`, write what
;; `take_outbound` drains, feed-refusal / `last_abort`, EOF / `break_far_vows` —
;; lives in `private/pump.rkt`. The public barrel (`pancake.rkt`) requires those
;; modules directly for app-facing symbols; this module requires them for CapTP
;; verbs and mint/handshake only.
;;
;; THE ACTION DRAIN. After any top-level host verb, the action queue drains
;; until dry (the one loop rule): a NEED_GIFT_ID draws 32 random bytes on the
;; spot, a FLUSH parks the named session's encoded outbound on its
;; pending-writes FIFO (via `drain-outbound!` in `pump.rkt`), and a DIAL parks
;; the executor among the drain's fires. The pops run under the host's
;; reentrant lock (`call-with-host`), so several green threads can share one
;; host — a server's accepted sessions, a gifter's exporter dial — while the C
;; host sees one caller at a time; everything that can block (socket writes,
;; dial executors, listener fires) runs after the lock releases. Reads happen
;; outside the lock too: `pump-until` (in `pump.rkt`) makes one thread the
;; session's reader (the `async-connection` reader gate) and parks everyone
;; else on the host's progress event, so a settle fired by a sibling session's
;; feed wakes a pump parked on its own quiet socket.

(require ffi/unsafe
         racket/string
         racket/async-channel
         "constants.rkt"
         "ffi-ocapn.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
         "value.rkt"
         "vat.rkt"
         "locator.rkt"
         "async.rkt"
         "host.rkt"
         "trampoline.rkt"
         "pump.rkt"
         "action.rkt"
         "promise.rkt"
         "gc.rkt")

(provide (all-defined-out)
         ;; Feed-refusal `last_abort` lives in pump; re-export for dogfood that
         ;; requires this module for CapTP verbs.
         session-last-abort)

;; A session carries its pump state (`async`), its vat, the `host` it
;; belongs to, and its `conn-id` — the opaque PancakeHostSession handle the host
;; minted for it. The host (endpoint half of Goblins `mycapn`; it owns
;; `engine.Node` for the router tables — ADR-0079) redeems three-party handoff
;; gives transparently and routes redeemed-capability sends to the exporter
;; that hosts them, so the application's `session-send`/`session-fetch`/
;; `session-tell` surface never sees a give. `pending-writes`/`write-gate`
;; carry encoded outbound frames from the locked action drain to the socket:
;; the drain pops `take_outbound` under the host lock (a host verb) into the
;; FIFO, and the write happens after the lock releases, under the per-session
;; gate — so a slow partner's socket stalls its own session's writer, never
;; every thread sharing the host. The FIFO is the order authority: whichever
;; thread holds the gate writes everything queued so far, in queue order, so
;; frames never reorder on the wire.
(struct session (async vat host conn-id pending-writes write-gate))

;; While true, a settle/fetch callback fired by a far-vow *break* (a dead
;; transport, a released connection) rather than a partner resolution, so the
;; awaiting verb classifies it as the typed ERR-CLOSED instead of ERR-BROKEN.
(define current-breaking (make-parameter #f))

(define (session-ptr c) (session-conn-id c))
(define (session-closed? c) (unbox (async-connection-closed? (session-async c))))
(define (session-released? c) (unbox (async-connection-released? (session-async c))))

(define (guard-open who c)
  (when (session-released? c)
    (raise-pancake who ERR-CLOSED "connection closed")))

;; Nonzero once the keyed handshake has completed and the session is open.
(define (session-open? c)
  (and (not (session-released? c))
       (= 1 (pancake_host_session_session_open (session-ptr c)))))

;; Distributed GC (`session-with-gc!` / `track-import!` / `drain-gc!`) lives in
;; `private/gc.rkt`. Feed-refusal / `session-last-abort` lives in `private/pump.rkt`.

;; ── The action drain ──────────────────────────────────────────────────────────
;; Decode + execute (`host-next-action!` / `drain-host-actions!`) live in
;; `private/action.rkt`. Conn byte path (feed / flush / EOF / `pump-until`)
;; lives in `private/pump.rkt`.

;; Write every session a drain flushed, tolerating a dead transport per
;; session so one broken partner never strands another's frames.
(define (write-touched! touched)
  (for ([c (in-list touched)])
    (with-handlers ([converts-to-broken? void]) (write-pending! c))))

;; Run the post-lock half of a drain: write flushed connections, then fire
;; deferred dials / settles / closes.
(define (run-drain-effects! fx)
  (write-touched! (drain-effects-touched fx))
  (for ([fire (in-list (drain-effects-fires fx))])
    (with-handlers ([converts-to-broken? void]) (fire))))

;; The one drain choreography every host-driving path shares: run `thunk`
;; under the host lock — it returns the locked drain's `drain-effects` (most
;; sites end in `drain-host-actions!`; some substitute `no-drain-effects` or a
;; merged record) plus any extra values — then run those effects (socket
;; writes, listener fires) after the lock releases, wake every parked pump,
;; and hand the extra values back to the caller.
(define (with-host-drain m thunk)
  (call-with-values
   (lambda () (call-with-host m thunk))
   (lambda (fx . rest)
     (run-drain-effects! fx)
     (host-bump-progress! m)
     (apply values rest))))

;; The breaking window the teardown paths share: unless `c` is already
;; released (its handle must see no further host verb), run `thunk` and drain
;; what it queued with completions classified as closure (`current-breaking`),
;; all inside one `with-host-drain`.
(define (with-breaking-drain c thunk)
  (define m (session-host c))
  (with-host-drain m
    (lambda ()
      (cond
        [(session-released? c) no-drain-effects]
        [else
         (parameterize ([current-breaking #t])
           (thunk)
           (drain-host-actions! m))]))))

;; Drain actions under the lock, write the flushed connections after it
;; releases, and wake every parked pump. A no-op inside a hosted turn: the
;; host refuses the driving verbs there, and everything the turn enqueued
;; flushes when the enclosing feed unwinds into this same drain.
(define (drain-host! m)
  (unless (inside-turn?)
    (host-drain-parked-releases! m)
    (with-host-drain m (lambda () (drain-host-actions! m)))))

;; Far-send / far-tell mint (`session-far-send`) lives in `promise.rkt`.

;; Break every far vow still parked on `c`, firing each listener with
;; `message` (or the partner's retained abort diagnostic when one arrived).
;; The vat-level `break-far-vows!` reaches here through the installed far half.
;; The FFI lives in pump; this wrapper owns the breaking-drain window.
(define (session-break-far-vows! c message)
  (with-breaking-drain c
    (lambda ()
      (break-far-vows-bytes! c (string->bytes/utf-8 message)))))

;; ── Construction: build, establish, dial, listen, accept ─────────────────────

;; Wrap a freshly minted host connection in a `connection`: build the pump
;; state and the vat, install the vat's far half, and join the host's registry
;; so a FLUSH action and a routed send can find it. The single place a
;; `connection` is born, so every path shares the same wiring.
(define (build-session m ptr transport time-travel?)
  (define ac (make-async-connection transport))
  (define v (make-vat #:time-travel? time-travel?))
  (define c (session ac v m ptr (make-async-channel) (make-semaphore 1)))
  (set-box! (async-connection-conn ac) c)
  (vat-install-far!
   v
   (far-ops (lambda (ref method args answer?) (session-far-send c ref method args answer?))
            (lambda (a-vow listener) (session-vow-listen! a-vow listener))
            (lambda (message) (session-break-far-vows! c message))))
  (host-register-session! m ptr c)
  c)

;; Retire the connection from the host and free the C handle: parked far vows
;; break inside the release (classified as closure), stranded sibling withdraws
;; fail closed, and the queued teardown effects drain.
(define (abandon-session! c)
  (define m (session-host c))
  (define ac (session-async c))
  (set-box! (async-connection-closed? ac) #t)
  (define ptr (session-ptr c))
  (cond
    [(inside-turn?)
     ;; Mid-turn: mark released, unregister, park the C free. Nested
     ;; `with-breaking-drain` would re-enter the feed's drain under the
     ;; trampoline latch and hang; the enclosing feed drains the park and
     ;; FAIL completions after the trampoline returns (Python/TS parity).
     (set-box! (async-connection-released? ac) #t)
     (host-unregister-session! m ptr)
     (host-park-release! m (lambda () (pancake_host_session_release ptr)))]
    [else
     ;; The abandoned connection's own parked frames die with it, but the drain
     ;; may flush a *different, healthy* connection (a sibling withdraw failing
     ;; closed), so the touched list is still written after the lock releases.
     ;; The breaking window: the release's queued FAIL completions classify as
     ;; closure.
     (with-breaking-drain c
       (lambda ()
         (set-box! (async-connection-released? ac) #t)
         (host-unregister-session! m ptr)
         (pancake_host_session_release ptr)))]))

;; Drive a freshly opened connection's keyed handshake to an open session,
;; abandoning the connection on any failure so a rude partner costs one
;; accept, never the listener. The read/feed loop lives in `run-handshake!`.
(define (finish-establish! c)
  (with-handlers ([(lambda (_) #t) (lambda (e) (abandon-session! c) (raise e))])
    (run-handshake! c)
    c))

;; Mint the dialing half from already-parsed locator pieces (a DIAL action's
;; transport + designator). Binding-internal. The transport seam companions
;; call this with a loop-driven transport (iroh) or a just-opened socket.
(define (establish-dialed-locator-session m transport-name designator transport
                                             #:time-travel? [time-travel? #f])
  (define tb (string->bytes/utf-8 transport-name))
  (define db (string->bytes/utf-8 designator))
  (define c
    (call-with-host m
      (lambda ()
        (define-values (rc ptr)
          (pancake_host_session_open_dialed_locator
           (host-ptr m)
           (pin-immobile tb) (bytes-length tb)
           (pin-immobile db) (bytes-length db)))
        (check/host rc)
        (build-session m ptr transport time-travel?))))
  (finish-establish! c))

;; Mint the accepting half over a connection the caller's own listener
;; produced: the keyed op:start-session signs the listener's own
;; `transport-name`/`designator` — the address a partner can actually dial, and
;; the locator a give made on this host names as the exporter location.
(define (establish-accepted-session m transport-name designator transport
                                       #:direct-addresses-hint [direct-addresses-hint ""]
                                       #:time-travel? [time-travel? #f])
  (define tb (string->bytes/utf-8 transport-name))
  (define db (string->bytes/utf-8 designator))
  (define hb (string->bytes/utf-8 direct-addresses-hint))
  (define c
    (call-with-host m
      (lambda ()
        (define-values (rc ptr)
          (pancake_host_session_open_accepted (host-ptr m)
                                           (pin-immobile tb) (bytes-length tb)
                                           (pin-immobile db) (bytes-length db)
                                           (pin-immobile hb) (bytes-length hb)))
        (check/host rc)
        (build-session m ptr transport time-travel?))))
  (finish-establish! c))

;; Record the dialable exporter location this session's gifter origination
;; signs into a give, in place of the exporter's own signed session record
;; (ADR-0009). `raw-locator` is the verbatim bytes from `encode-peer-locator`
;; (read off the registered exporter URI). A rendezvous that learned a member's
;; iroh URI sets it so a give can name an exporter reachable only by a dial hint
;; under the relay-less `Direct` posture. Unset, origination uses the partner's
;; signed location.
(define (session-set-exporter-locator! c raw-locator)
  (call-with-host (session-host c)
    (lambda ()
      (check/host (pancake_host_session_set_exporter_location
                   (session-ptr c) (pin-immobile raw-locator) (bytes-length raw-locator))))))

;; Flush whatever is already queued on the host's outbound to the wire. A `<-`
;; far-send only enqueues; the bytes leave when something drains. The blocking
;; verbs drain themselves, but work another green thread queues onto this host
;; — a server pushing a broadcast to a subscriber whose own thread is parked
;; reading — would sit unsent until that thread woke. Call `session-flush!` right
;; after such a cross-thread send to put the bytes on the wire now.
(define (session-flush! c)
  (define m (session-host c))
  (unless (inside-turn?)
    (with-host-drain m
      (lambda ()
        ;; This session is flushed whether or not an action named it, so it
        ;; is merged into the drained effects' touched list.
        (define drained (drain-host-actions! m))
        (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
        (define touched (drain-effects-touched drained))
        (drain-effects (if (memq c touched) touched (cons c touched))
                       (drain-effects-fires drained))))))

;; Named `session-close!` with the full prefix, keeping the
;; application-surface close distinct from the netlayer's `endpoint-release!`.
;; Close the session: stop the transport first, then retire the host's
;; entry and free the host handle, so no foreign call touches a freed
;; session.
(define (session-close! c)
  (define ac (session-async c))
  ((async-transport-close! (async-connection-transport ac)))
  (abandon-session! c))

;; ── Spawning, publishing, and the proxy verbs ─────────────────────────────────

;; Spawn/publish hosting mint (`register-hosted-actor!`) lives in
;; `trampoline.rkt`.

;; Spawn a local actor at a fresh export position and return a near capability
;; to hand a partner. `(session-spawn c ^name arg …)` constructs like `spawn`. The
;; position comes from the session's one export allocator, so it can never
;; alias a bootstrap or resolver export. Callable from inside a served turn (a
;; factory's `create` minting the task it replies with).
(define (session-spawn c constructor . args)
  (define actor (with-vat (session-vat c) (apply spawn constructor args)))
  (register-hosted-actor! c actor))

;; Publish an actor fetchable by name (a swiss-number). Returns the near
;; capability.
(define (session-publish c name constructor . args)
  (define actor (with-vat (session-vat c) (apply spawn constructor args)))
  (register-hosted-actor! c actor #:name name))

;; Wrap `target` (a near capability this session spawned or a far one it
;; fetched) in a revocable caretaker (ADR-0064). Returns the proxy near capability
;; to hand a partner; every call through it forwards to `target` until
;; `session-revoke!`, after which each breaks with "Revoked". `target` may be a
;; capability imported over the wire — the proxy forwards transparently — so this
;; hands out a revocable view of authority you do not own locally.
(define (session-caretaker c target)
  (caretaker-proxy c target))

;; Wrap `target` in an attenuator (ADR-0064): a proxy that forwards only the
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
;; fire-and-forget sibling is `session-tell`. A `near-ref` this session spawned
;; resolves in process; a partner's ref goes out on the wire, and a redeemed
;; handoff token routes to the exporter connection that hosts it. A broken
;; reply raises a typed `exn:fail:pancake` carrying PANCAKE_ERR_BROKEN, exactly
;; as the Python and Rust `send`s fail. Single-threaded: it pumps events
;; itself, matching the rest of the Racket binding. The local arm is
;; `session-send-local` in `trampoline.rkt`.
(define (session-send c target verb . args)
  (guard-open 'session-send c)
  (drain-gc! c) ; flush any imports reclaimed since the last session op
  (dispatch-send c target verb args))

;; Eventual-send `verb` to `target` and return its vow WITHOUT driving the
;; session to a reply — the non-blocking half of `session-send` and the seam
;; for promise pipelining (ADR-0007). The returned vow is itself a valid
;; `target` for a later `session-send`/`session-send-promise`/`session-tell`, so a
;; dependent call rides a `desc:answer` deliver the partner queues until the
;; answer settles; a `create -> use` chain then costs one round trip. The
;; deliver is queued now and its bytes leave the wire when the chain is settled
;; by passing its tail to `session-send` (which pumps to the value) — a chain
;; never settled is fire-and-forget, for which `session-tell` is the right call.
;; A `near-ref` this session spawned resolves in process.
(define (session-send-promise c target verb . args)
  (guard-open 'session-send-promise c)
  (dispatch-send-promise c target verb args))

;; Drive the connection until `a-vow` settles, returning its fulfilled value,
;; the awaiting half of `session-send-promise` / `session-index` / `session-untag`. A
;; broken vow raises a typed `exn:fail:pancake` (PANCAKE_ERR_BROKEN), as
;; `session-send` does. A local vow settles in `drive`; a far vow on a wire reply
;; — or immediately, when the resolution already arrived while a sibling
;; projection pumped the loop. Single-threaded: it pumps events itself, like
;; the rest of the binding.
(define (session-await c a-vow)
  (cond
    [(session-vow? a-vow) (await-vow c a-vow 'session-await "the vow")]
    [(local-vow? a-vow) (await-local-vow c a-vow 'session-await "the vow")]
    [else
     (raise-pancake 'session-await ERR-INVALID-ARGUMENT "not a vow: ~a" a-vow)]))

;; Fetch a partner's published capability by name, returning the far
;; reference. The canonical fetch lives in the library: one call registers the
;; bootstrap import, allocates the answer, and queues the deliver; the host
;; enrolls the fulfilled capability under a node-unique token (ADR-0069)
;; before the completion fires, so two capabilities fetched at the same wire
;; position on different connections never collide, and a return re-gifts the
;; right home. A partner break raises a typed pancake failure
;; (PANCAKE_ERR_BROKEN); a fetch that fulfills with anything but a capability
;; raises a typed unsupported-value failure, the same code the Python binding
;; uses for the same shape. The shared mint→await→classify body is
;; `blocking-fetch` in `promise.rkt`.
(define (session-fetch c name)
  (guard-open 'session-fetch c)
  (drain-gc! c) ; flush any imports reclaimed since the last connection op
  (define nb (string->bytes/utf-8 name))
  (track-import!
   c
   (blocking-fetch c 'session-fetch "fetch" name
                   (lambda ()
                     (pancake_host_session_fetch (session-ptr c) (pin-immobile nb)
                                              (bytes-length nb))))))

;; Enliven a sturdyref against this session (ADR-0012): bring the durable
;; `(peer, swissnum)` to life as a live capability. Parses `sturdyref` for its
;; swissnum, then fetches it through the host's dedup cache — a repeat enliven
;; of the same swissnum on this session short-circuits with no wire traffic
;; (its SETTLE completion is queued before the minting call returns). The
;; session must already be open to the sturdyref's peer; the sans-io core
;; tracks no remote locator and never dials. A partner break raises a typed
;; PANCAKE_ERR_BROKEN; a fulfill that is not a capability raises the typed
;; unsupported-value failure, matching `session-fetch` and the other bindings.
(define (session-enliven c sturdyref)
  (guard-open 'session-enliven c)
  (define swissnum
    (string->bytes/utf-8 (locator-swissnum (parse-locator sturdyref #:sturdyref? #t))))
  (blocking-fetch c 'session-enliven "enliven" sturdyref
                  (lambda ()
                    (pancake_host_session_enliven (session-ptr c) (pin-immobile swissnum)
                                               (bytes-length swissnum)))))

;; Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and no
;; reply comes back, so a notification or broadcast costs one deliver. A
;; self-spawned target runs its turn in-process (like `session-send`); a far one
;; flushes the deliver to the wire.
(define (session-tell c target verb . args)
  (guard-open 'session-tell c)
  (dispatch-tell c target verb args))

;; Drive inbound frames into the host until the connection closes: hosted
;; actors run, far vows settle, and the host's actions execute, all inside the
;; pump. When the wire is gone the pump has already broken every far vow still
;; awaiting a reply (with the partner's retained abort diagnostic when one
;; arrived), the same disconnect guarantee the Deno and Python connections give.
(define (session-serve c)
  (drain-gc! c)
  (pump-until c
              (lambda () (and (session-closed? c) 'closed))
              'session-serve)
  (void))
