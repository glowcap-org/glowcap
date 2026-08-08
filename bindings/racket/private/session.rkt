#lang racket/base
;; Internal: the CapTP `session` surface over the byte-fed host
;; (libpancake_host, ADR-0072 / ADR-0079). It owns the `session` struct and
;; every `session-*` application verb (`session-fetch`, `session-send`,
;; `session-tell`, `session-serve`, …), plus mint/handshake (`establish-*`).
;; The dial executor (plan + channel open + `connect`) lives in
;; `private/dial.rkt`. Server/`listen`/`accept` live in `private/listen.rkt`.
;; The host action switch (`drain-host-actions!`) lives
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
;; session's reader (the `async-connection` reader gate), parks drain effects
;; until that gate clears, and parks every other pump on the host's progress
;; event — so a settle another session's feed recorded wakes a pump parked on
;; its own quiet socket without sharing the reader window with a write or fire.

(require ffi/unsafe
         racket/string
         racket/async-channel
         "constants.rkt"
         "codec.rkt"
         "ffi-ocapn.rkt"
         "ffi-host.rkt"
         "errors.rkt"
         "value.rkt"
         "vat.rkt"
         "locator.rkt"
         "async.rkt"
         "host.rkt"
         "trace.rkt"
         "trampoline.rkt"
         "pump.rkt"
         "action.rkt"
         "promise.rkt"
         "gc.rkt")

(provide (all-defined-out)
         ;; Feed-refusal `last_abort` lives in pump; re-export for dogfood that
         ;; requires this module for CapTP verbs. The handshake bound lives
         ;; there too, beside the deadline machinery dial and accept share;
         ;; re-export it for the public barrel.
         session-last-abort
         HANDSHAKE-TIMEOUT-MS)

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
;; `owns-host?` is a box set when this session created the host it runs on,
;; which `connect` does when the caller passes no `#:host`. Such a host has no
;; other reachable owner, so closing the session releases it; a caller-supplied
;; host is never released here, because sibling sessions may still be using it.
(struct session (async vat host conn-id pending-writes write-gate owns-host?))

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
       (= 1 (pancake_host_session_is_open (session-ptr c)))))

;; Distributed GC (`session-with-gc!` / `track-import!` / `drain-gc!`) lives in
;; `private/gc.rkt`. Feed-refusal / `session-last-abort` lives in `private/pump.rkt`.

;; ── The action drain ──────────────────────────────────────────────────────────
;; Decode + execute (`drain-host-actions!`) live in
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

;; Merge two drain-effects records in FIFO order (earlier first). Used when a
;; reader-held feed nests further locked drains under the same deferral box.
(define (merge-drain-effects a b)
  (drain-effects
   (append (drain-effects-touched a) (drain-effects-touched b))
   (append (drain-effects-fires a) (drain-effects-fires b))))

;; The one drain choreography every host-driving path shares: run `thunk`
;; under the host lock — it returns the locked drain's `drain-effects` (most
;; sites end in `drain-host-actions!`; some substitute `no-drain-effects` or a
;; merged record) plus any extra values — then run those effects (socket
;; writes, listener fires) after the lock releases, wake every parked pump,
;; and hand the extra values back to the caller. Under
;; `current-defer-drain-effects` (pump.rkt), only the merge happens here; the
;; reader after-thunk owns effects + bump.
(define (with-host-drain m thunk)
  (call-with-values
   (lambda () (call-with-host m thunk))
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
         (lambda () (run-drain-effects! fx))
         (lambda () (host-bump-progress! m)))
        (apply values rest)]))))

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
    (drain-host-gc! m)
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
  (define c (session ac v m ptr (make-async-channel) (make-semaphore 1) (box #f)))
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
  ;; The handle must see exactly one release: the mid-turn arm parks an
  ;; unconditional release closure, so a second abandon (two mid-turn closes
  ;; coalesced into one feed, or a repeated `session-close!`) would park a
  ;; double free without this guard. The Python/TS/Rust sessions carry the
  ;; same released? early-out.
  (unless (session-released? c)
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
       ;; The abandoned connection's own parked frames die with it, but the
       ;; drain may flush a *different, healthy* connection (a sibling withdraw
       ;; failing closed), so the touched list is still written after the lock
       ;; releases. The breaking window: the release's queued FAIL completions
       ;; classify as closure.
       (with-breaking-drain c
         (lambda ()
           (set-box! (async-connection-released? ac) #t)
           (host-unregister-session! m ptr)
           (pancake_host_session_release ptr)))])))

;; Drive a freshly opened connection's keyed handshake to an open session,
;; abandoning the connection on any failure so a rude partner costs one
;; accept, never the listener. `timeout-ms` bounds the wait; #f and 0 leave it
;; unbounded. The read/feed loop lives in `run-handshake!`.
(define (finish-establish! c timeout-ms)
  (with-handlers ([(lambda (_) #t) (lambda (e) (abandon-session! c) (raise e))])
    (run-handshake! c timeout-ms)
    c))

;; Run one mint + handshake window; any failure inside it closes `transport`
;; before the error escapes, so a failed establish never leaks the byte
;; channel behind it. The close lives here, not at dial/accept sites — the
;; Rust and Python bindings keep the same rule inside their establish — and
;; every transport's close is idempotent, so a later `session-close!` on the
;; survivor stays safe.
(define (establish-closing-transport transport thunk)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (with-handlers ([(lambda (_) #t) void])
                       ((async-transport-close! transport)))
                     (raise e))])
    (thunk)))

;; Mint the dialing half from already-parsed locator pieces (a DIAL action's
;; transport + designator). Binding-internal. The transport seam companions
;; call this with a loop-driven transport (iroh) or a just-opened socket.
;; The handshake is bounded by default, the same `HANDSHAKE-TIMEOUT-MS` the
;; accepted half below uses and the same bound the Rust, Python, and TypeScript
;; dials carry: a partner that takes the connection and then never finishes the
;; handshake is a hang, not a slow success. A caller that holds its own
;; cancellation passes #f (or 0) to wait forever.
(define (establish-dialed-locator-session m transport-name designator transport
                                             #:time-travel? [time-travel? #f]
                                             #:verified-channel-key
                                             [verified-channel-key #f]
                                             #:handshake-timeout-ms
                                             [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (establish-closing-transport transport
    (lambda ()
      (define tb (string->bytes/utf-8 transport-name))
      (define db (string->bytes/utf-8 designator))
      (define c
        (call-with-host m
          (lambda ()
            (host-ensure-advertised-locator! m transport-name)
            (define-values (rc ptr)
              (pancake_host_session_open_dialed_locator
               (host-ptr m)
               (pin-immobile tb) (bytes-length tb)
               (pin-immobile db) (bytes-length db)))
            (check/host rc)
            (build-session m ptr transport time-travel?))))
      ;; Before the first partner byte, which is the only window a realizer's
      ;; proof can be weighed in.
      (when verified-channel-key
        (session-bind-verified-channel-key! c verified-channel-key))
      (finish-establish! c handshake-timeout-ms))))

;; Mint the accepting half over a connection the caller's own listener
;; produced. `server-designator` is the listener's signing designator (key for
;; keyed-tcp/iroh; unused for tcp); `accepted-local-addr` is what accept
;; reported. Signing designator/hint come from `pancake_host_plan_accept`
;; (ADR-0078). The handshake is bounded by default — see
;; `accept-next-session`, which every listening surface goes through.
(define (establish-accepted-session m transport-name server-designator transport
                                       #:accepted-local-addr [accepted-local-addr ""]
                                       #:time-travel? [time-travel? #f]
                                       #:verified-channel-key
                                       [verified-channel-key #f]
                                       #:handshake-timeout-ms
                                       [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (establish-closing-transport transport
    (lambda ()
      (define tb (string->bytes/utf-8 transport-name))
      (define sb (string->bytes/utf-8 server-designator))
      (define lb (string->bytes/utf-8 accepted-local-addr))
      (define c
        (call-with-host m
          (lambda ()
            ;; Pin once: plan_accept views borrow these (or the static
            ;; unreachable placeholder); pass those pointers into open_accepted
            ;; with no copy.
            (define tpin (pin-immobile tb))
            (define spin (pin-immobile sb))
            (define lpin (pin-immobile lb))
            (define plan (make-PancakeAcceptPlan #f 0 #f 0))
            (check/host (pancake_host_plan_accept
                         tpin (bytes-length tb)
                         spin (bytes-length sb)
                         lpin (bytes-length lb)
                         plan))
            (define (plan-text ptr len)
              (if (or (not ptr) (zero? len))
                  ""
                  (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD)))
            (host-set-advertised-locator!
             m
             (encode-peer-locator
              transport-name
              (plan-text (PancakeAcceptPlan-designator plan)
                         (PancakeAcceptPlan-designator-len plan))
              (plan-text (PancakeAcceptPlan-direct-addresses-hint plan)
                         (PancakeAcceptPlan-direct-addresses-hint-len plan))))
            (define-values (rc ptr)
              (pancake_host_session_open_accepted (host-ptr m)
                                                   tpin (bytes-length tb)))
            (check/host rc)
            (build-session m ptr transport time-travel?))))
      ;; Before the first partner byte, which is the only window a realizer's
      ;; proof can be weighed in.
      (when verified-channel-key
        (session-bind-verified-channel-key! c verified-channel-key))
      (finish-establish! c handshake-timeout-ms))))

;; The one accept rule every listening surface shares — tcp, keyed-tcp, and
;; iroh all reach the wire through here. `next-partner` blocks for the next
;; partner and returns two values: its `async-transport` and the local address
;; accept reported.
;;
;; Both halves of the rule protect the listener from a partner it did not
;; choose. A rude probe — connect and hang up, a port scan, a key mismatch —
;; fails its own handshake, and a partner that connects and then says nothing
;; never fails at all, so only `HANDSHAKE-TIMEOUT-MS` ends that wait. Either
;; costs this one accept and the loop moves to the next partner, matching the
;; Rust, Python, and TypeScript listeners; without both, one probe parks or
;; ends a server's accept loop. A skipped partner leaves nothing behind:
;; `establish-closing-transport` closes its transport exactly once on the way
;; out, whether the handshake failed or timed out.
;;
;; The handler predicate is `converts-to-broken?`, not a catch-all, so a
;; `break-thread` aimed at the accepting thread still terminates it instead of
;; being absorbed into a retry. What `next-partner` itself raises — a closed
;; listener — propagates: that ends the loop, as it should.
(define (accept-next-session m transport-name server-designator next-partner
                                #:time-travel? [time-travel? #f]
                                #:handshake-timeout-ms
                                [handshake-timeout-ms HANDSHAKE-TIMEOUT-MS])
  (let loop ()
    ;; Three facts come out of an accept: the byte channel, where it came from,
    ;; and what the code that accepted it proved about the far end (`#f` on a
    ;; socket, which proves nothing; an endpoint id on iroh).
    (define-values (transport accepted-local-addr verified-channel-key)
      (next-partner))
    (define c
      (with-handlers ([converts-to-broken? (lambda (_e) #f)])
        (establish-accepted-session m transport-name server-designator transport
                                       #:accepted-local-addr accepted-local-addr
                                       #:time-travel? time-travel?
                                       #:verified-channel-key verified-channel-key
                                       #:handshake-timeout-ms handshake-timeout-ms)))
    (or c (loop))))

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

;; Who this session's partner proved itself to be, as a `partner-identity`: the
;; partner's session public key, the location designator it signed, and the
;; verbatim location record those were read from.
;;
;; Getting an answer here always means the signature was checked. A keyed
;; `op:start-session` carries an Ed25519 signature over the partner's whole
;; location record, and the engine verifies that signature before the session
;; opens, so the designator this returns is bound to the key beside it by the
;; same signature. That is what lets a server refuse a caller claiming a
;; locator it does not own: compare the locator the caller hands you against
;; the designator here, and turn the call away when the two disagree.
;;
;; The library lends these bytes for as long as the session lives, so each view
;; is copied into a fresh Racket value before this returns. It raises while the
;; partner's `op:start-session` has not arrived with a key yet, and it raises on
;; a session opened without partner verification, because there is no proved
;; identity to read on one.
(define (session-partner-identity c)
  (guard-open 'session-partner-identity c)
  (call-with-host (session-host c)
    (lambda ()
      (define out (make-PancakePartnerIdentity #f 0 #f 0 #f 0 0))
      (check/host (pancake_host_session_partner_identity (session-ptr c) out))
      (partner-identity
       (bytes<-c (PancakePartnerIdentity-session-key out)
                 (PancakePartnerIdentity-session-key-len out))
       (bytes->string/utf-8
        (bytes<-c (PancakePartnerIdentity-designator out)
                  (PancakePartnerIdentity-designator-len out))
        #\uFFFD)
       (bytes<-c (PancakePartnerIdentity-locator-record out)
                 (PancakePartnerIdentity-locator-record-len out))
       (provenance<-abi (PancakePartnerIdentity-provenance out))))))

;; Testify what proved this connection's far end, when your own transport proved
;; one.
;;
;; pancake does not open your sockets, so it cannot see what opening them
;; established. An iroh connection completes only with the holder of the node id
;; you dialed or accepted, and that is a stronger fact than anything a partner
;; can claim about itself, but only you hold it. Pass the node id here and
;; `session-partner-identity` reports `authenticated-transport`; withhold it and
;; the same session reports `unauthenticated`.
;;
;; `designator` is that identity as a locator writes it, which is exactly what
;; the iroh transport's remote node id hands you.
;;
;; Call it after opening the session and before feeding the first byte from the
;; partner. It raises afterwards, because by then the handshake this evidence
;; was for has already been judged. Naming a second, different identity raises
;; too: one connection has one far end. Naming the same one twice is the same
;; statement made twice and is fine.
(define (session-bind-verified-channel-key! c designator)
  (guard-open 'session-bind-verified-channel-key! c)
  (define raw (string->bytes/utf-8 designator))
  (call-with-host (session-host c)
    (lambda ()
      (check/host (pancake_host_session_bind_verified_channel_key
                   (session-ptr c) (pin-immobile raw) (bytes-length raw))))))

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
  (abandon-session! c)
  ;; A host this session created has no other owner, so it goes too, and with
  ;; it every connection it dialed for redeems. A caller-supplied host stays:
  ;; sibling sessions on it are still running.
  (when (unbox (session-owns-host? c)) (host-release! (session-host c))))

;; Let `host-release!` close the sessions it still holds. host.rkt cannot name
;; `session-close!` directly: this module requires it, and Racket has no
;; module cycles.
(set-box! close-session-hook session-close!)

;; ── Spawning, publishing, and the proxy verbs ─────────────────────────────────

;; Spawn/publish hosting mint (`register-hosted-actor!`) lives in
;; `trampoline.rkt`.

;; Spawn a local actor and return its opaque Host capability to hand a partner.
;; `(session-spawn c ^name arg …)` constructs like `spawn`. Wire export
;; positions stay inside pancake. Callable from inside a served turn (a
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
;; publisher: `host-publish-giftable` hosts one actor under a Host-wide alias
;; and returns nothing. Reading its Host identity lazily projects it onto this
;; session so an application can pass it as an ordinary capability argument.
;;
;; A giftable is a bare trampoline closure here rather than a vat actor, so the
;; result is for handing to a partner: unlike a `session-spawn` capability, a
;; local send to it is not composed in Racket.
(define (session-published-ref c name)
  (define m (session-host c))
  (define nb (string->bytes/utf-8 name))
  (define-values (rc capability)
    (call-with-host m
      (lambda ()
        (pancake_host_session_published_ref
         (session-ptr c) (pin-immobile nb) (bytes-length nb)))))
  (cond
    [(= rc ERR-NOT-FOUND) #f]
    [else (check/host rc) (make-ref/internal (PancakeReference-id capability))]))

;; Wrap `target` in a revocable caretaker (ADR-0064). Returns the proxy capability
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
;; fire-and-forget sibling is `session-tell`. A reference this session spawned
;; resolves in process; a partner's ref goes out on the wire, and a redeemed
;; handoff token routes to the exporter connection that hosts it. A broken
;; reply raises a typed `exn:fail:pancake` carrying PANCAKE_ERR_BROKEN, exactly
;; as the Python and Rust `send`s fail. Single-threaded: it pumps events
;; itself, matching the rest of the Racket binding. The local arm is
;; `session-send-local` in `trampoline.rkt`.
;; Listen on a far capability this session holds (CapTP op:listen): the
;; returned vow settles with the listen notification, which may be any value,
;; not only a capability. In 1.0, the target may be a far promise or live far
;; object; in pancake-next, the target must be a promise. A re-gifted promise
;; routes to its exporter session transparently.
(define (session-listen c target)
  (guard-open 'session-listen c)
  (drain-gc! c)
  (listen-far c target))

(define (session-send c target verb . args)
  (guard-open 'session-send c)
  (drain-gc! c) ; flush any imports reclaimed since the last session op
  (dispatch-send c target verb args))

;; Eventual-send `verb` to `target`, drive the session to the reply exactly as
;; `session-send` does, and also hand back the direct session that reply lives
;; on: `(values reply via)`.
;;
;; When `target` answers with a three-party handoff give — a room's `introduce`
;; naming another member, say — this host redeems it by dialing the exporter,
;; and the reply settles as a capability hosted on that fresh direct
;; connection. The connection is otherwise internal to the binding. `via` is
;; it, so the caller can spawn or publish its own objects on the very
;; connection the redeemed capability lives on. That is the one place a
;; capability handed back to the exporter is valid: an OCapN near export names
;; a position on one specific connection's peer, so an inbox spawned on the
;; introducing session means nothing to the exporter that receives it.
;;
;; `via` is #f whenever no such connection is in play: the reply is not a live
;; capability at all, or it is an ordinary far reply from `target` itself, or
;; its exporter connection has already gone. `(or via c)` is then the session
;; to work on, and the caller needs no separate case for the two.
;;
;; The exporter is resolved from the reply's own route rather than from
;; whichever dial this host finished most recently. So it stays exact with
;; several introductions in flight at once, and a reply whose exporter an
;; earlier redeem already dialed resolves to that live session with no second
;; connection opened.
(define (session-send-redeeming c target verb . args)
  (guard-open 'session-send-redeeming c)
  (drain-gc! c) ; flush any imports reclaimed since the last session op
  (define reply (dispatch-send c target verb args))
  (define home (and (ref? reply) (host-exporter-for (session-host c) reply)))
  (values reply (and home (not (eq? home c)) home)))

;; Eventual-send `verb` to `target` and return its vow WITHOUT driving the
;; session to a reply — the non-blocking half of `session-send` and the seam
;; for promise pipelining (ADR-0007). The returned vow is itself a valid
;; `target` for a later `session-send`/`session-send-promise`/`session-tell`, so a
;; dependent call rides a `desc:answer` deliver the partner queues until the
;; answer settles; a `create -> use` chain then costs one round trip. The
;; deliver is queued now and its bytes leave the wire when the chain is settled
;; by passing its tail to `session-send` (which pumps to the value) — a chain
;; never settled is fire-and-forget, for which `session-tell` is the right call.
;; A reference this session spawned resolves in process.
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

;; Enliven a sturdyref against this session (ADR-0098): bring the durable
;; `(peer, swissnum)` to life as a live capability. The host verifies the full
;; locator against this session before consulting its dedup cache — a repeat enliven
;; of the same swissnum on this session short-circuits with no wire traffic
;; (its SETTLE completion is queued before the minting call returns). The
;; session must already be open to the sturdyref's peer; this session-level
;; call never dials. A partner break raises a typed
;; PANCAKE_ERR_BROKEN; a fulfill that is not a capability raises the typed
;; unsupported-value failure, matching `session-fetch` and the other bindings.
(define (session-enliven c sturdyref)
  (guard-open 'session-enliven c)
  (define sturdyref-bytes (string->bytes/utf-8 sturdyref))
  (blocking-fetch c 'session-enliven "enliven" sturdyref
                  (lambda ()
                    (pancake_host_session_enliven (session-ptr c) (pin-immobile sturdyref-bytes)
                                               (bytes-length sturdyref-bytes)))))

;; Fire-and-forget eventual-send (Goblins `<-np`): no answer is allocated and no
;; reply comes back, so a notification or broadcast costs one deliver. A
;; self-spawned target runs its turn in-process (like `session-send`); a far one
;; flushes the deliver to the wire.
;; Annotate this session for the live trace: the application states
;; which partner it carries (a chat nick), a claim about naming
;; carried beside the protocol facts. Fire-and-forget like every
;; trace emit.
(define (session-annotate! c #:label label)
  (trace-annotate-session! (host-ptr (session-host c)) (session-ptr c) label))

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
;; `session-send` parks forever on a half-open TCP socket — the Python serve
;; loop's `finally` closes for the same reason.
(define (session-serve c)
  (drain-gc! c)
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (with-handlers ([(lambda (_) #t) void])
                       (session-close! c))
                     (raise e))])
    (pump-until c
                (lambda () (and (session-closed? c) 'closed))
                'session-serve)
    (void)))

;; ── Host-level select-or-dial enliven (ADR-0098) ──────────────────────────────
;; Enliven a complete sturdyref against the host: select a live session this
;; host already dialed to the sturdyref's peer, or stage a dial and settle
;; over the opened session. The blocking wait is host-scoped — the vow
;; belongs to no session (its row's conn is #f, and no session's teardown
;; sweeps it), the initial drain runs a staged dial in this thread, the
;; dialed exporter serves itself on its own thread (`run-dial!`), and this
;; thread parks on host progress until the settle lands. The dial executor's
;; failure handler breaks the vow, so the wait always ends. Every binding's
;; `pancake_host_enliven` contract: the full sturdyref verifies before wire
;; traffic, and a session-scoped repeat rides `session-enliven`'s cache.
(define (host-enliven m sturdyref)
  (when (unbox (host-released? m))
    (raise-pancake 'host-enliven ERR-CLOSED "host released"))
  (define sturdyref-bytes (string->bytes/utf-8 sturdyref))
  (define v
    (call-with-host m
      (lambda ()
        (define-values (rc id)
          (pancake_host_enliven (host-ptr m) (pin-immobile sturdyref-bytes)
                                (bytes-length sturdyref-bytes)))
        (check/host rc)
        (define fresh (session-vow #f id 'pending '()))
        (register-vow! m fresh)
        fresh)))
  ;; Fire the staged work: a cache-hit's pre-queued settle, or the dial
  ;; action whose executor opens the exporter session and its serve thread.
  (with-host-drain m (lambda () (drain-host-actions! m)))
  (let loop ()
    (define s (session-vow-state v))
    (cond
      [(eq? s 'pending)
       ;; Snapshot, re-check, then park: the bump posts the snapshot under
       ;; the host lock, so a settle between the check and the sync still
       ;; wakes this waiter (the pump-until idiom, host-scoped).
       (define gen (host-progress-evt m))
       (when (eq? (session-vow-state v) 'pending) (sync gen))
       (loop)]
      [(eq? (car s) 'ok)
       (define val (cdr s))
       (unless (ref? val)
         (raise-pancake 'host-enliven ERR-UNSUPPORTED-VALUE
                        "enliven \"~a\" did not resolve to a capability: ~a" sturdyref val))
       val]
      [else
       (raise-pancake 'host-enliven ERR-BROKEN "enliven \"~a\" broke: ~a" sturdyref (cdr s))])))

;; ── Off-turn settlement: the resolver pair ────────────────────────────────────
;; A behavior mints a pair with `host-spawn-resolver` (legal inside a turn,
;; which is the primary use), defers its answer onto the pair's vow with
;; `resolver-forward-turn!`, parks the resolver for whatever completes the
;; work, and returns; the completion settles it later with
;; `resolver-fulfill!` / `resolver-break!` as its own top-level event. One
;; settle per resolver — a second refuses — and a deferred settle carries
;; plain data only: a value that names a capability is refused, and an answer
;; that carries authority forwards to a send instead.

(struct resolver (host vow-id id))

;; Mint a resolver pair on `m`.
(define (host-spawn-resolver m)
  (call-with-host m
    (lambda ()
      (define-values (rc vow-id resolver-id) (pancake_host_spawn_resolver (host-ptr m)))
      (check/host rc)
      (resolver m vow-id resolver-id))))

;; Defer the current turn's answer onto `r`'s vow: the answer settles when
;; the resolver does. Legal only inside a behavior hosted by `r`'s host.
(define (resolver-forward-turn! r)
  (define t (current-turn))
  (unless t
    (error 'resolver-forward-turn! "a turn verb: call it inside a behavior"))
  (unless (eq? (session-host (cdr t)) (resolver-host r))
    (error 'resolver-forward-turn! "the turn belongs to another host"))
  (check/host (pancake_host_turn_forward_vow (car t) (resolver-vow-id r))))

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
      (check/host (pancake_host_resolver_fulfill
                   (host-ptr m) (resolver-id r)
                   (cast aptr _pointer _PancakeArgument-pointer)))
      (drain-host-actions! m))))

;; Settle the deferred answer broken with the worker's own words.
(define (resolver-break! r reason)
  (define m (resolver-host r))
  (with-host-drain m
    (lambda ()
      (define rb (string->bytes/utf-8 reason))
      (check/host (pancake_host_resolver_break (host-ptr m) (resolver-id r)
                                               (pin-immobile rb) (bytes-length rb)))
      (drain-host-actions! m))))
