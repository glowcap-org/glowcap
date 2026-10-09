#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require net/base64
         (only-in ffi/unsafe ctype-sizeof)
         racket/async-channel
         racket/random
         racket/runtime-path
         "../../glowcap.rkt"
         "../../glowcap-tcp.rkt"
         "../../glowcap-inproc.rkt"
         "../../glowcap-onion.rkt"
         "../../glowcap-iroh.rkt"
         (combine-in "../../private/session.rkt"
                     "../../private/session/state.rkt"
                     "../../private/session/establish.rkt"
                     "../../private/session/close.rkt")
         (combine-in "../../private/host.rkt" "../../private/host/state.rkt")
         (only-in "../../private/iroh.rkt" iroh-endpoint-record-failure!)
         "../../private/locator.rkt"
         "../../private/async.rkt"
         "../../private/byte-channel.rkt"
         (only-in "../../private/finalizer-diagnostics.rkt"
                  record-runtime-failure! run-native-finalizer!)
         (only-in "../../private/ws-transport.rkt" ws-transport)
         (only-in "../../relay.rkt" relay-pump exn:fail:relay?
                  exn:fail:relay-primary exn:fail:relay-secondary)
         "../../private/pump.rkt"
         "../../private/action.rkt"
         (only-in "../../private/dial.rkt" retain-host-cleanup-failure!)
         "../../private/promise.rkt"
         "../../private/gc.rkt"
         "../../private/vat.rkt"
         "../../private/ffi-host.rkt"
         "../../private/ffi-ocapn.rkt"
         "../../private/ffi-shared.rkt"
         "../../private/errors.rkt"
         "../../private/constants.rkt"
         "../../private/abi-value.rkt"
         (only-in "../../private/loop.rkt"
                  open-driver-loop driver-loop-start! driver-loop-abort!
                  loop-background-failed!
                  driver-loop-has-transport?
                  loop-listen! loop-listener-ready! loop-listener-locator
                  loop-listener-close!)
         "../../private/native-parent.rkt"
         (only-in "../../private/value.rkt" make-ref/internal)
         "support.rkt"
         racket/tcp)

;; ── Time-travel: restore retargets wire delivers ──────────────────────────────
;; The README's headline time-travel claim, pinned over the wire: snapshot a
;; served vat, mutate the actor through wire delivers, restore, and observe
;; the NEXT wire deliver hit the restored behavior — proving `vat-restore!`
;; retargets what the trampoline dispatches, not just local `$` calls.
(define tt-server (listen "127.0.0.1" 0 #:time-travel? #t))
(define tt-ready (make-semaphore 0))
(define tt-vat-box (box #f))
(define tt-host
  (thread
   (lambda ()
     (define hsession (accept tt-server))
     (set-box! tt-vat-box (session-vat hsession))
     (session-publish hsession "counter" ^counter 10)
     (semaphore-post tt-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession)))))
(define tt-session (open-test-session (tcp-locator "127.0.0.1" (server-port tt-server))))
(semaphore-wait tt-ready)
(define tt-cap (session-fetch tt-session "counter"))
(expect (= 15 (session-send tt-session tt-cap 'add 5)) "time-travel: first wire add lands")
(define tt-snap (vat-snapshot (unbox tt-vat-box)))
(expect (= 115 (session-send tt-session tt-cap 'add 100)) "time-travel: second wire add lands")
(vat-restore! (unbox tt-vat-box) tt-snap)
;; The next WIRE deliver must see the restored state (15), not the later one.
(expect (= 15 (session-send tt-session tt-cap 'get))
        "time-travel: restore retargeted the wire deliver to the snapshot state")
(expect (= 22 (session-send tt-session tt-cap 'add 7))
        "time-travel: the restored behavior keeps serving from the snapshot")
(session-close! tt-session)
(server-close! tt-server)

(printf "racket zig-smoke OK: vat-restore! retargets wire delivers to the snapshot state\n")

;; ── Listener fires run outside the host lock ──────────────────────────────────
;; An `on` listener is arbitrary application code; the drain that settles its
;; vow runs under the host lock, so the fire itself is deferred to after the
;; lock releases — a listener that ran under the lock could wedge every other
;; thread sharing the host. The listener proves it directly: at fire time this
;; thread must not own the host lock, and an enqueueing verb (a tell) must go
;; through. (Fires also run after the reader gate clears, so a listener may
;; pump this connection — but must not block the reader turn that produced
;; the settle; enqueue and return.)
(define lf-server (listen "127.0.0.1" 0))
(define lf-ready (make-semaphore 0))
(define lf-told (make-async-channel))
(define lf-acceptor
  (thread
   (lambda ()
     (define hsession (accept lf-server))
     (session-publish hsession "svc"
                   (lambda (bcom)
                     (methods
                      [(first) 1]
                      [(notify) (async-channel-put lf-told 'told) 2])))
     (semaphore-post lf-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession)))))
(define lf-session (open-test-session (tcp-locator "127.0.0.1" (server-port lf-server))))
(semaphore-wait lf-ready)
(define lf-svc (session-fetch lf-session "svc"))
(define lf-host (session-host lf-session))
(define lf-under-lock (box 'unfired))
(define lf-vow (with-vat (session-vat lf-session) (<- lf-svc 'first)))
(with-vat (session-vat lf-session)
  (on lf-vow
      (lambda (v)
        (set-box! lf-under-lock (eq? (unbox (host-lock-owner lf-host)) (current-thread)))
        ;; An enqueueing verb from inside the fire: legal, takes the host lock
        ;; the fire no longer holds.
        (session-tell lf-session lf-svc 'notify))))
(expect (= 1 (session-await lf-session lf-vow)) "listener-fire: the send settled")
(expect (eq? #f (unbox lf-under-lock))
        "listener-fire: the fire ran with the host lock released")
(expect (eq? 'told (sync/timeout 10 lf-told))
        "listener-fire: the listener's tell reached the partner")
(session-close! lf-session)
(server-close! lf-server)

(printf "racket zig-smoke OK: an on listener fires outside the host lock and can enqueue\n")

;; ── Alias-only unpublish ──────────────────────────────────────────────────────
;; Discovery moves, the issued capability does not: after
;; `host-unpublish` a fetch of the name breaks even on the session
;; that fetched it before, a second removal is a loud #f, and the ref fetched
;; before removal still answers.
(define up-server (listen "127.0.0.1" 0))
(host-publish (server-host up-server) "ephemeral" (methods [(probe) 11]))
(define up-held (box #f))
(define up-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept up-server))
       (set-box! up-held (session-published-ref hsession "ephemeral"))
       (session-serve hsession)))))
(define up-session (open-test-session (tcp-locator "127.0.0.1" (server-port up-server))))
(define up-cap (session-fetch up-session "ephemeral"))
(expect (equal? 11 (session-send up-session up-cap 'probe)) "unpublish: the alias fetches and answers before removal")
(expect (eq? #t (host-unpublish (server-host up-server) "ephemeral"))
        "unpublish: removing a live alias reports #t")
(expect (eq? #f (host-unpublish (server-host up-server) "ephemeral"))
        "unpublish: removing an absent alias reports #f")
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (session-fetch up-session "ephemeral")
          #f)
        "unpublish: a fetch of the removed alias breaks on the session that fetched it")
(expect (equal? 11 (session-send up-session up-cap 'probe))
        "unpublish: the capability issued before removal still answers")

;; Durable publication (ADR-0098): the minted swiss name fetches on the live
;; session, removal makes a later fetch miss, and the capability issued before
;; removal still answers.
(define up-swiss (host-publish-durable (server-host up-server) (methods [(probe) 21])))
(expect (and (= 50 (string-length up-swiss))
             (equal? "glowcap-durable-1-" (substring up-swiss 0 18)))
        "durable: the minted swiss carries the durable prefix and length")
(define up-durable (session-fetch up-session up-swiss))
(expect (equal? 21 (session-send up-session up-durable 'probe))
        "durable: the minted swiss fetches and answers")
(expect (eq? #t (host-remove-durable (server-host up-server) up-swiss))
        "durable: removing a live durable name reports #t")
(expect (eq? #f (host-remove-durable (server-host up-server) up-swiss))
        "durable: removing an absent durable name reports #f")
(expect (with-handlers ([exn:fail? (lambda (_) #t)])
          (session-fetch up-session up-swiss)
          #f)
        "durable: a fetch of the removed name breaks")
(expect (equal? 21 (session-send up-session up-durable 'probe))
        "durable: the capability issued before removal still answers")
(define up-exact-name (host-publish-reference (server-host up-server) (unbox up-held)))
(define up-exact (session-fetch up-session up-exact-name))
(expect (equal? 11 (session-send up-session up-exact 'probe))
        "reference publication: exact original actor answers after alias removal")
(expect (host-remove-durable (server-host up-server) up-exact-name)
        "reference publication: remove its independent root")
(expect (equal? 11 (session-send up-session up-exact 'probe))
        "reference publication: issued capability survives name removal")
(session-close! up-session)
(kill-thread up-thread)
(server-close! up-server)

;; Retained durable entropy restores the same swiss name after reconstructing
;; a Host from the same seed, refuses a live collision without retaining a
;; second trampoline, and refuses the wrong width before minting anything.
(define de-seed (make-bytes 32 7))
(define de-entropy (make-bytes HOST-DURABLE-ENTROPY-LEN 3))
(define de-host (make-host de-seed))
(define de-name (host-publish-durable de-host (lambda _ (void)) de-entropy))
(define de-keep (hash-count (host-keep de-host)))
(define de-collision
  (with-handlers ([exn:fail:glowcap? values])
    (host-publish-durable de-host (lambda _ (void)) de-entropy)))
(expect (exn:fail:glowcap? de-collision)
        "durable-entropy: a live name with the same entropy is refused")
(expect (= de-keep (hash-count (host-keep de-host)))
        "durable-entropy: refused publish does not retain a second trampoline")
(define de-short
  (with-handlers ([exn:fail:glowcap? values])
    (host-publish-durable de-host (lambda _ (void)) (make-bytes 1 0))))
(expect (and (exn:fail:glowcap? de-short)
             (= ERR-INVALID-ARGUMENT (exn:fail:glowcap-code de-short))
             (= de-keep (hash-count (host-keep de-host))))
        "durable-entropy: the wrong width is refused before minting a trampoline")
(expect (host-remove-durable de-host de-name)
        "durable-entropy: remove the live name")
(expect (equal? de-name (host-publish-durable de-host (lambda _ (void)) de-entropy))
        "durable-entropy: the same entropy restores the same name after remove")
(host-close! de-host)
(define de-restored (make-host de-seed))
(expect (equal? de-name (host-publish-durable de-restored (lambda _ (void)) de-entropy))
        "durable-entropy: the same seed and entropy restore the name")
(define de-other
  (host-publish-durable de-restored (lambda _ (void))
                        (make-bytes HOST-DURABLE-ENTROPY-LEN 4)))
(expect (not (equal? de-other de-name))
        "durable-entropy: different entropy mints a different name")
(host-close! de-restored)

(printf "racket zig-smoke OK: retained durable entropy restores names and refuses live collisions\n")

;; ── A redeem dial must not park the host ──────────────────────────────────────
;; The recipient half of a three-party handoff opens its own socket to the
;; exporter (a DIAL action). A dial is a connect syscall plus a whole keyed
;; handshake, so the drain defers it post-lock like every write and fire: a
;; slow exporter stalls that one redeem, never every thread sharing the host.
;; Proven with a deterministic stall in a raw byte relay — the redeem dial has
;; connected, but the relay has not yet opened its exporter leg, so its
;; handshake parks — while a sibling connection on the recipient's host
;; completes a full send. Releasing the relay then lets the parked redeem
;; finish end-to-end, which also proves the whole hermetic three-party flow:
;; gift originated by the gifter's host, deposited on the exporter, withdrawn
;; over a real DIAL, and the redeemed capability called directly.
(define rd-e-server (listen "127.0.0.1" 0))
;; Host-wide, not session-published: deposit retains the actor before the
;; recipient's redeem dial opens, and withdrawal projects that exact actor onto
;; the new exporter session without resolving the alias again.
(host-publish (server-host rd-e-server) "gifted"
                       (let ([n (box 7)])
                         (methods [(use) (unbox n)]
                                  [(bump) (set-box! n 8) 8])))
(define rd-release-relay (make-semaphore 0))
(define rd-dial-reached (make-semaphore 0))
(define-values (rd-relay rd-relay-port)
  (start-sniffing-relay
   (server-port rd-e-server)
   (lambda (_chunk) #f)
   #:before-connect
   (lambda ()
     (semaphore-post rd-dial-reached)
     (semaphore-wait rd-release-relay))))
(define rd-e-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       ;; Accept exactly one connection now — the gifter's — and serve it so
       ;; the gifter's deposit is read. The second accept waits for the relay
       ;; to open its exporter leg after the stalled-dial assertion.
       (define hsession (accept rd-e-server))
       (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))
       (define rconn (accept rd-e-server))
       (with-handlers ([(lambda (_) #t) void]) (session-serve rconn))))))
(define rd-g-server (listen "127.0.0.1" 0))
;; Sibling probe peer: a second listen so the recipient host can hold two
;; live sessions without a second dial to the same address designator
;; (SessionPairExists). Same host, different partner — that is the lock pin.
(define rd-ping-server (listen "127.0.0.1" 0))
;; The gifter dials the exporter on its server's host, so the tool it fetches
;; and the introductions it serves share one identity and handoff router.
(define rd-gc (open-test-session (tcp-locator "127.0.0.1" (server-port rd-e-server))
                       #:adopt-host (server-host rd-g-server)))
(session-set-exporter-locator!
 rd-gc
 (locator TRANSPORT-TCP
          (tcp-address-designator "127.0.0.1" rd-relay-port)
          (hash)
          'map))
(define rd-tool (session-fetch rd-gc "gifted"))
;; Mutate the tool through the gifter, then replace the alias with a decoy:
;; the later withdrawal must project the exact mutated actor the gifter holds,
;; never whatever the name resolves to at withdraw time (ADR-0096, on the
;; binding path).
(expect (= 8 (session-send rd-gc rd-tool 'bump))
        "redeem-dial: the gifter mutated the tool before introducing it")
(host-publish (server-host rd-e-server) "gifted" (methods [(use) 0]))
(define rd-g-ready (make-semaphore 0))
(define rd-g-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (let accept-loop ([first? #t])
         (define hsession (accept rd-g-server))
         (session-publish hsession "intro"
                       (lambda (bcom)
                         (methods
                          ;; Replying with a capability that lives on another
                          ;; connection makes the host originate a give.
                          [(get-tool) rd-tool])))
         (when first? (semaphore-post rd-g-ready))
         (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))
         (accept-loop #f))))))
(define rd-ping-ready (make-semaphore 0))
(define rd-ping-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept rd-ping-server))
       (session-publish hsession "ping"
                     (lambda (bcom) (methods [(ping) "pong"])))
       (semaphore-post rd-ping-ready)
       (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))))
(define rd-r-main (open-test-session (tcp-locator "127.0.0.1" (server-port rd-g-server))))
(semaphore-wait rd-g-ready)
(define rd-r-side (open-test-session (tcp-locator "127.0.0.1" (server-port rd-ping-server))
                           #:adopt-host (session-host rd-r-main)))
(semaphore-wait rd-ping-ready)
(define rd-intro-main (session-fetch rd-r-main "intro"))
(define rd-ping-side (session-fetch rd-r-side "ping"))
;; Trigger the handoff: the reply is a give, the recipient's host auto-redeems
;; it, and the send settles only after the withdraw — so this thread is parked
;; in the stalled dial until the exporter is released.
(define rd-tool-ch (make-channel))
(void (thread
       (lambda ()
         (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rd-tool-ch e))])
           (channel-put rd-tool-ch (session-send rd-r-main rd-intro-main 'get-tool))))))
;; The dial is provably in flight once the relay accepts it. Its exporter leg
;; remains unopened until `rd-release-relay` is posted below.
(expect (sync/timeout 30 rd-dial-reached)
        "redeem-dial: the redeem dial never reached the exporter relay")
;; THE PIN: with the dial stalled mid-handshake, a sibling connection sharing
;; the recipient's host must still complete a full send. If the dial executor
;; held the host lock, this send would wedge and the timeout would fail loud.
(define rd-probe-ch (make-channel))
(void (thread
       (lambda ()
         (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rd-probe-ch e))])
           (channel-put rd-probe-ch (session-send rd-r-side rd-ping-side 'ping))))))
(define rd-probe (sync/timeout 15 rd-probe-ch))
(expect (equal? rd-probe "pong")
        "redeem-dial: a sibling send settled while the dial was stalled")
;; Release the relay: the parked handshake completes, the withdraw settles,
;; and the redeemed capability answers a direct call.
(semaphore-post rd-release-relay)
(define rd-tool-cap (sync/timeout 30 rd-tool-ch))
(expect (and rd-tool-cap (not (exn? rd-tool-cap)))
        "redeem-dial: the gifted capability settled after the exporter released")
(expect (= 8 (session-send rd-r-main rd-tool-cap 'use))
        "redeem-dial: the redeemed capability is the exact mutated actor, not the alias's decoy")
(session-close! rd-r-main)
(session-close! rd-r-side)
(session-close! rd-gc)
(tcp-close rd-relay)
(server-close! rd-g-server)
(server-close! rd-ping-server)
(server-close! rd-e-server)

(printf "racket zig-smoke OK: a redeem dial runs post-lock and a stalled exporter parks one redeem, not the host\n")

;; ── Answering across an introduction: session-send-redeeming's `via` ──────────
;; An introduction answers with a capability whose home is a different
;; session: the host redeems the give by dialing the exporter, and the reply
;; lives in that fresh direct session rather than the session the introduction
;; arrived over. `session-send-redeeming` returns that session as `via`. It
;; matters because an OCapN near export names a position in one specific
;; session, so an inbox the caller hands back to the exporter is only meaningful
;; when it was spawned in the session through which the exporter is reached.
;; This scene proves the whole loop: `via` is a live session, an ordinary send
;; to the redeemed capability rides it, and an inbox
;; spawned on it is reachable — the exporter calls it and the note arrives. The
;; last two expectations pin the #f arm, where no redeemed route is in play.
(define sr-e-server (listen "127.0.0.1" 0))
;; The session the recipient's redeem dial opens. The exporter answers the
;; caller's inbox over it, which is the far half of the same claim.
(define sr-direct (box #f))
(host-publish
 (server-host sr-e-server)
 "gifted"
 (methods
  [(use) 7]
  [(dm text inbox)
   ;; A hosted turn must not drive the host, so a separate thread tells the
   ;; caller's inbox and flushes it, exactly as the cross-thread scene above.
   (thread (lambda ()
             (with-handlers ([(lambda (_) #t) void])
               (define d (unbox sr-direct))
               (session-tell d inbox 'note text)
               (session-flush! d))))
   "sent"]))
(define sr-e-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (let accept-loop ([n 0])
         (define hsession (accept sr-e-server))
         ;; The first partner is the gifter depositing the gift; the second is
         ;; the recipient's redeem dial, the session an inbox belongs in.
         (unless (zero? n) (set-box! sr-direct hsession))
         (thread
          (lambda ()
            (with-handlers ([(lambda (_) #t) void])
              (session-serve hsession))))
         (accept-loop (add1 n)))))))
(define sr-g-server (listen "127.0.0.1" 0))
(define sr-gc (open-test-session (tcp-locator "127.0.0.1" (server-port sr-e-server))
                       #:adopt-host (server-host sr-g-server)))
(define sr-tool (session-fetch sr-gc "gifted"))
(define sr-g-ready (make-semaphore 0))
(define sr-g-thread
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept sr-g-server))
       ;; Spawned before the turn, not inside it: a hosted method may not drive
       ;; the host, and this is the ordinary-reply control for the scene.
       (define own (session-spawn hsession (lambda (bcom) (methods [(hi) "hi"]))))
       (session-publish hsession "intro"
                        (lambda (bcom)
                          (methods
                           ;; A capability hosted on another connection, so
                           ;; replying with it makes the host originate a give.
                           [(get-tool) sr-tool]
                           ;; A capability of this session's own.
                           [(get-own) own])))
       (semaphore-post sr-g-ready)
       (session-serve hsession)))))
;; Keep the recipient Host byte-fed so the handoff redeem must realize its
;; exporter TCP channel on the same active Host, never transfer that Host into
;; the native driver after its broker session exists.
(define sr-r-loc (tcp-locator "127.0.0.1" (server-port sr-g-server)))
(define sr-r-host (make-fresh-host))
(define sr-r
  (open-test-session sr-r-loc #:adopt-host sr-r-host #:connector (tcp-connector)))
(semaphore-wait sr-g-ready)
(define sr-intro (session-fetch sr-r "intro"))
(define-values (sr-tool-cap sr-via) (session-send-redeeming sr-r sr-intro 'get-tool))
(expect (session? sr-via)
        "send-redeeming: the redeemed reply surfaced its exporter session")
(expect (not (eq? sr-via sr-r))
        "send-redeeming: the exporter session is not the introducing session")
(expect (= 7 (session-send sr-via sr-tool-cap 'use))
        "send-redeeming: the redeemed capability answered over its own session")
;; The point of the whole verb: an inbox spawned on `via` is a position the
;; exporter can reach, so the exporter's reply lands in it.
(define sr-note (box #f))
(define sr-noted (make-semaphore 0))
(define sr-inbox
  (session-spawn sr-via
                 (lambda (bcom)
                   (methods [(note text) (set-box! sr-note text) (semaphore-post sr-noted)]))))
(expect (equal? "sent" (session-send sr-via sr-tool-cap 'dm "hello" sr-inbox))
        "send-redeeming: the direct session carried the reply inbox to the exporter")
(expect (sync/timeout 30 sr-noted)
        "send-redeeming: the exporter reached the inbox hosted on the direct session")
(expect (equal? "hello" (unbox sr-note))
        "send-redeeming: the exporter's answer arrived on the direct session")
;; An ordinary far reply names no redeemed route, so there is nothing to
;; surface and `via` is #f. A caller then works on the session it already has.
(define-values (sr-own-cap sr-own-via) (session-send-redeeming sr-r sr-intro 'get-own))
(expect (eq? #f sr-own-via)
        "send-redeeming: an ordinary far reply has no exporter session")
(expect (equal? "hi" (session-send (or sr-own-via sr-r) sr-own-cap 'hi))
        "send-redeeming: (or via c) is the session an ordinary reply works on")
(session-close! sr-r)
(session-close! sr-gc)
(server-close! sr-g-server)
(server-close! sr-e-server)

(printf "racket zig-smoke OK: session-send-redeeming surfaces the direct session a redeemed reply lives on\n")
