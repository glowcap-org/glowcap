#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require net/base64
         (only-in ffi/unsafe ctype-sizeof)
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

;; ── Session parity: self-spawned sends resolve in process; failures are typed ─
;; A host publishes `svc` (whose `boom` method raises) and serves. The client
;; proves three contracts the other bindings already pin: a send/tell to a Ref
;; this same session spawned resolves in process (the server hosts no such
;; export, so a wire route would never reply, mirroring Rust's
;; send_to_a_self_spawned_actor_resolves_in_process); a partner break raises a
;; typed exn:fail:glowcap carrying GLOWCAP_ERR_BROKEN; and a failed fetch
;; re-raises that typed failure untouched.
(define cp-server (listen "127.0.0.1" 0))
(define cp-ready (make-semaphore 0))
(define cp-ch (make-channel))
(define cp-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put cp-ch e))])
       (define hsession (accept cp-server))
       (define published
         (session-publish hsession "svc"
                          (lambda (bcom)
                            (methods
                             [(boom) (error 'svc "deliberate failure")]))))
       (define observed (session-published-ref hsession "svc"))
       (expect (and (ref? observed) (= (ref-id observed) (ref-id published)))
               "published-ref reuses the opaque Host identity")
       (semaphore-post cp-ready)
       (session-serve hsession)
       (channel-put cp-ch 'served)))))

(define cp-session (open-test-session (tcp-locator "127.0.0.1" (server-port cp-server))))
(semaphore-wait cp-ready)

;; Self-spawned send and tell: the client never runs a serve loop, so only an
;; in-process turn can settle these.
(define cp-me (session-spawn cp-session ^counter 10))
(expect (ref? cp-me) "self-spawn: session-spawn returns a capability")
(expect (= 15 (session-send cp-session cp-me 'add 5)) "self-spawn: session-send resolved in process")
(session-tell cp-session cp-me 'add 100)
(expect (= 115 (session-send cp-session cp-me 'get)) "self-spawn: session-tell ran the local turn")
(define cp-failing
  (session-spawn cp-session
                 (lambda (_bcom)
                   (lambda (_method . _args) (error 'notice "local tell failed")))))
(session-tell cp-session cp-failing 'notify)
(define cp-tell-failures (host-take-failures! (session-host cp-session)))
(expect (and (= (length cp-tell-failures) 1)
             (equal? (failure-event-operation (car cp-tell-failures)) "tell.behavior")
             (positive? (failure-event-scope-id (car cp-tell-failures)))
             (regexp-match? #rx"local tell failed"
                            (failure-event-primary-message (car cp-tell-failures))))
        "self-spawn: local tell failure enters the Host diagnostic seam")

;; A partner break is a typed glowcap failure carrying GLOWCAP_ERR_BROKEN.
(define cp-svc (session-fetch cp-session "svc"))
(define cp-broken
  (with-handlers ([exn:fail:glowcap? values])
    (session-send cp-session cp-svc 'boom)
    'no-error))
(expect (exn:fail:glowcap? cp-broken) "break: session-send raised exn:fail:glowcap")
(expect (equal? ERR-BROKEN (exn:fail:glowcap-code cp-broken)) "break: code is GLOWCAP_ERR_BROKEN")
(expect (regexp-match? #rx"deliberate failure" (exn-message cp-broken))
        "break: the partner's own diagnostic crossed the wire")

;; A fetch of an unpublished name breaks too, and session-fetch re-raises the typed
;; failure untouched instead of flattening it to a generic exn:fail.
(define cp-missing
  (with-handlers ([exn:fail:glowcap? values])
    (session-fetch cp-session "no-such-name")
    'no-error))
(expect (exn:fail:glowcap? cp-missing) "fetch: an unknown name raised exn:fail:glowcap")
(expect (equal? ERR-BROKEN (exn:fail:glowcap-code cp-missing)) "fetch: code is GLOWCAP_ERR_BROKEN")

(session-close! cp-session)
(define cp-host-result (channel-get cp-ch))
(when (exn? cp-host-result) (raise cp-host-result))
(expect (eq? 'served cp-host-result) "connection parity: host served to a clean close")
(server-close! cp-server)

(printf "racket zig-smoke OK: self-spawned sends resolve in process and failures are typed\n")

;; ── Cross-connection argument: inline handoff routes the capability ───────────
;; A capability fetched on one connection can ride another connection's send
;; through the draft's inline handoff projection. Nesting it in a list preserves
;; the explicit route. Core and live-Goblins scenarios own redemption semantics;
;; this binding dogfood proves Racket projects the nested promise as a Ref.
(define fa-server-1 (listen "127.0.0.1" 0))
(define fa-server-2 (listen "127.0.0.1" 0))
(define fa-ready-1 (make-semaphore 0))
(define fa-ready-2 (make-semaphore 0))
(define (fa-serve! server ready role)
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept server))
       (session-publish
        hsession "svc"
        (lambda (bcom)
          (case role
            [(exporter) (methods [(ping x) x])]
            [(recipient)
             (methods
              [(use payload)
               (expect (and (list? payload)
                            (= 3 (length payload))
                            (ref? (cadr payload)))
                       "foreign arg: recipient observed the nested handoff promise")
               (sym "received-handoff")])])))
       (semaphore-post ready)
       (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))))))
(void (fa-serve! fa-server-1 fa-ready-1 'exporter))
(void (fa-serve! fa-server-2 fa-ready-2 'recipient))
(define fa-session-1 (open-test-session (tcp-locator "127.0.0.1" (server-port fa-server-1))))
(semaphore-wait fa-ready-1)
(define fa-session-2 (open-test-session (tcp-locator "127.0.0.1" (server-port fa-server-2))
                           #:adopt-host (session-host fa-session-1)))
(semaphore-wait fa-ready-2)
(define fa-cap-1 (session-fetch fa-session-1 "svc"))
(define fa-cap-2 (session-fetch fa-session-2 "svc"))
(define fa-result (session-send fa-session-2 fa-cap-2 'use (list 1 fa-cap-1 2)))
(expect (equal? (sym "received-handoff") fa-result)
        "foreign arg: the recipient received the nested capability")
(session-close! fa-session-1)
(session-close! fa-session-2)
(server-close! fa-server-1)
(server-close! fa-server-2)

(printf "racket zig-smoke OK: a nested cross-connection argument projects as a Ref\n")

;; ── Promise pipelining: the questioner's half (ADR-0007) ──────────────────────
;; `session-send-promise` returns a far vow that is itself a `send` target, so
;; a create -> assign -> complete -> status chain is issued against the
;; create answer even after a fast resolution. The board's `create` spawns a fresh task
;; mid-turn and returns it; the partner's engine queues the pipelined calls on
;; that pending answer and drains them onto the task once create resolves. A
;; status of `done` proves the chain crossed the wire without round-tripping
;; per link.
(define (^task bcom [done #f])
  (methods
   [(assign who) "assigned"]
   [(complete)   (bcom (^task bcom #t) "done")]
   [(status)     (if done "done" "open")]))

(define pl-server (listen "127.0.0.1" 0))
(define pl-ready (make-semaphore 0))
(define pl-ch (make-channel))
(define pl-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pl-ch e))])
       (define hsession (accept pl-server))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(create name) (session-spawn hsession ^task)]
                        [(barrier) "ready"])))
       (semaphore-post pl-ready)
       (session-serve hsession)
       (channel-put pl-ch 'served)))))

(define pl-session (open-test-session (tcp-locator "127.0.0.1" (server-port pl-server))))
(semaphore-wait pl-ready)
(define pl-root (session-fetch pl-session "root"))
;; An ordered call on the same session proves the client consumed the preceding
;; create resolution before building the dependent chain. The public vow still
;; owns that answer position until its finalizer releases it.
(define pl-task (session-send-promise pl-session pl-root 'create "benchmark"))
(expect (equal? "ready" (session-send pl-session pl-root 'barrier))
        "pipelining: the ordered barrier settled")
(session-tell pl-session pl-task 'assign "alice")
(void (session-send-promise pl-session pl-task 'complete))
(define pl-status (session-send pl-session pl-task 'status))
(expect (equal? "done" pl-status) "pipelining: the chained status settled to done")

(define pl2-server (listen "127.0.0.1" 0))
(define pl2-ready (make-semaphore 0))
(define pl2-ch (make-channel))
(define pl2-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pl2-ch e))])
       (define hsession (accept pl2-server))
       (session-publish hsession "root"
                        (lambda (bcom)
                          (methods
                           [(create name) (session-spawn hsession ^task)])))
       (semaphore-post pl2-ready)
       (session-serve hsession)
       (channel-put pl2-ch 'served)))))
(define pl2-session (open-test-session (tcp-locator "127.0.0.1" (server-port pl2-server))))
(semaphore-wait pl2-ready)
(define pl2-root (session-fetch pl2-session "root"))
(define pl2-task (session-send-promise pl2-session pl2-root 'create "second"))
(expect (= (session-vow-id pl-task) (session-vow-id pl2-task))
        "host-scope: the scenario exercises colliding vow ids")
;; The refusal happens before any FFI call, and it arrives on the handle the
;; send returns. `session-send-promise` has to return before its answer settles
;; so a caller can pipeline at it, so a refusal raised at the call would land on
;; a channel the caller's settle-side handler never watches.
(define foreign-vow-handle (session-send-promise pl2-session pl-task 'status))
(define foreign-vow-error
  (with-handlers ([exn:fail:glowcap? values])
    (session-await pl2-session foreign-vow-handle)
    'no-error))
(expect (and (exn:fail:glowcap? foreign-vow-error)
             (= ERR-INVALID-ARGUMENT (exn:fail:glowcap-code foreign-vow-error)))
        "host-scope: a foreign vow is refused before FFI")
(define foreign-projection-error
  (with-handlers ([exn:fail:glowcap? values])
    (session-index pl2-session pl-task 0)
    'no-error))
(expect (and (exn:fail:glowcap? foreign-projection-error)
             (= ERR-INVALID-ARGUMENT
                (exn:fail:glowcap-code foreign-projection-error)))
        "host-scope: a foreign projection is refused before FFI")
(expect (equal? "open" (session-send pl2-session pl2-task 'status))
        "host-scope: the destination vow remains exact")
(session-close! pl2-session)
(define pl2-host-result (channel-get pl2-ch))
(when (exn? pl2-host-result) (raise pl2-host-result))
(expect (eq? 'served pl2-host-result) "host-scope: second Host served to a clean close")
(server-close! pl2-server)

(session-close! pl-session)
(define pl-host-result (channel-get pl-ch))
(when (exn? pl-host-result) (raise pl-host-result))
(expect (eq? 'served pl-host-result) "pipelining: host served to a clean close")
(server-close! pl-server)

(printf "racket zig-smoke OK: public vows remain pipeline targets and colliding ids stay Host-scoped\n")

;; ── Promise-pipeline saturation stays typed and terminal ─────────────────────
;; A queue cap of one admits the first call aimed at an unresolved answer and
;; refuses the second. Both calls travel in the same feed batch, before the
;; create behavior can settle its answer. The refusal must remain the Session's
;; one terminal result through serve and every close observer.
(define qs-host (make-fresh-host))
(host-set-ingress-limits! qs-host #:max-pending-turns 4096
                         #:max-pending-bytes (* 1024 1024) #:max-chunk-bytes (* 128 1024))
(host-set-session-limits! qs-host #:queue-cap 1 #:max-retained-sent-answer-bytes (* 8 1024 1024))
(define qs-server (listen "127.0.0.1" 0 #:host qs-host))
(define qs-ready (make-semaphore 0))
(define qs-parked (box #f))
(define qs-parked-ready (make-semaphore 0))
(define qs-result (make-channel))
(define qs-server-thread
  (thread
   (lambda ()
     (define hsession (accept qs-server))
     (host-publish
      (session-host hsession) "root"
      (lambda (method . _args)
        (unless (eq? method 'create) (error 'queue-saturation "unexpected method"))
        (define pair (host-defer-turn (session-host hsession)))
        (set-box! qs-parked pair)
        (semaphore-post qs-parked-ready)
        (void)))
     (semaphore-post qs-ready)
     (define serve-failure
       (with-handlers ([exn:fail:glowcap? values])
         (session-serve hsession)
         'served))
     (define close-failure
       (with-handlers ([exn:fail:glowcap? values])
         (session-close! hsession)
         'closed))
     (define repeated-close-failure
       (with-handlers ([exn:fail:glowcap? values])
         (session-close! hsession)
         'closed))
     (channel-put qs-result
                  (list serve-failure close-failure repeated-close-failure
                        (session-released? hsession))))))

(define qs-session
  (open-test-session (tcp-locator "127.0.0.1" (server-port qs-server))))
(semaphore-wait qs-ready)
(define qs-root (session-fetch qs-session "root"))
(define qs-task (session-send-promise qs-session qs-root 'create))
(semaphore-wait qs-parked-ready)
(session-tell qs-session qs-task 'assign "first")
(define qs-saturated
  (session-send-promise qs-session qs-task 'assign "saturated"))
(define qs-client-failure
  (with-handlers ([exn:fail:glowcap? values])
    (session-await qs-session qs-saturated)
    'settled))
(define qs-observed (sync/timeout 10 qs-result))
(expect qs-observed "queue saturation: exporter serve did not terminate")
(define qs-serve-failure (list-ref qs-observed 0))
(define qs-close-failure (list-ref qs-observed 1))
(define qs-repeated-close-failure (list-ref qs-observed 2))
(define qs-abort
  (and (exn:fail:glowcap? qs-serve-failure)
       (exn:fail:glowcap-abort qs-serve-failure)))
(expect (and (exn:fail:glowcap? qs-client-failure)
             (= ERR-CLOSED (exn:fail:glowcap-code qs-client-failure))
             (exn:fail:glowcap? qs-serve-failure)
             (= ERR-SESSION (exn:fail:glowcap-code qs-serve-failure))
             (abort-info? qs-abort)
             (equal? "QueueCapExceeded" (abort-info-kind qs-abort)))
        (format "queue saturation: exact terminal results missing (client ~a, server ~a, abort ~a)"
                qs-client-failure qs-serve-failure qs-abort))
(expect (and (eq? qs-serve-failure qs-close-failure)
             (eq? qs-serve-failure qs-repeated-close-failure)
             (list-ref qs-observed 3))
        "queue saturation: close lost the terminal exception or retired state")
(session-close! qs-session)
(server-close! qs-server)
(host-close! qs-host)
(thread-wait qs-server-thread)

(printf "racket zig-smoke OK: queue saturation stays exact through serve and repeated close\n")

;; ── Pipelined projections (ADR-0050/ADR-0052) ─────────────────────────────────
;; `session-untag`/`session-index` project a tag/element out of a far
;; vow *before it settles*, each returning a new pipelinable vow. The board's
;; `make` returns a `("assigned" label 7)` row wrapped in a "task" tag; `untag`
;; unwraps the single-value tag to that row and `index 1` takes the label, a
;; two-hop chain riding the unresolved `make` answer, no extra round trip. The
;; source vow is then awaited to prove a far reply that landed *before* its
;; listener (while a sibling projection pumped the loop) still settles from the
;; vow's recorded state. (`get` projects a Struct, which the Racket value model
;; surfaces as a tagged/struct arg; index and untag are the
;; cross-binding-comparable pair, so they are what this dogfood asserts,
;; matching Python.)
(define pj-server (listen "127.0.0.1" 0 #:codec 'capnp #:captp-version 'next #:features 'full))
(define pj-ready (make-semaphore 0))
(define pj-release (make-semaphore 0))
(define pj-resolver-ready (make-semaphore 0))
(define pj-pipeline-sent (make-semaphore 0))
(define pj-trace-uninstall
  (enable-trace!
   (lambda (ev)
     (when (and (equal? (hash-ref ev 'kind #f) "ocapn.message-decoded")
                (hash-ref ev 'outbound #f)
                (equal? (hash-ref ev 'op #f) "pipeline-sentinel"))
       (semaphore-post pj-pipeline-sent)))))
(define pj-resolver (box #f))
(define pj-ch (make-channel))
(define pj-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pj-ch e))])
       (define hsession (accept pj-server))
       (define hprofile (session-profile hsession))
       (expect (equal? (settled-profile-captp-version hprofile) 'next)
               "projections: accepted session reports glowcap-next")
       (expect (equal? (settled-profile-codec hprofile) 'capnp)
               "projections: accepted session reports Cap'n Proto")
       (expect (= (settled-profile-features hprofile) FEATURE-FULL)
               "projections: accepted session reports the full feature set")
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(make label)
                         (set-box! pj-resolver (host-defer-turn (session-host hsession)))
                         (semaphore-post pj-resolver-ready)
                         (void)]
                        [(release)
                         (semaphore-post pj-release)
                         "released"])))
       (semaphore-post pj-ready)
       (define settle
         (thread
          (lambda ()
            (semaphore-wait pj-resolver-ready)
            (semaphore-wait pj-release)
            (resolver-fulfill!
             (unbox pj-resolver)
             (tagged-arg "task" (list (list "assigned" "alice" 7)))))))
       (session-serve hsession)
       (thread-wait settle)
       (channel-put pj-ch 'served)))))

(define pj-session (open-test-session (tcp-locator "127.0.0.1" (server-port pj-server))
                            #:codec 'capnp
                            #:captp-version 'next
                            #:features 'full))
(define pj-profile (session-profile pj-session))
(expect (equal? (settled-profile-captp-version pj-profile) 'next)
        "projections: dialed session reports glowcap-next")
(expect (equal? (settled-profile-codec pj-profile) 'capnp)
        "projections: dialed session reports Cap'n Proto")
(expect (= (settled-profile-features pj-profile) FEATURE-FULL)
        "projections: dialed session reports the full feature set")
(semaphore-wait pj-ready)
(define pj-root (session-fetch pj-session "root"))
;; Neither projection waits for make's reply: they ride the unresolved make
;; answer and the whole chain leaves on one pump.
(define pj-made (session-send-promise pj-session pj-root 'make "alice"))
(define pj-label (session-index pj-session (session-untag pj-session pj-made "task") 1))
(session-tell pj-session pj-label 'pipeline-sentinel)
(semaphore-wait pj-pipeline-sent)
(expect (equal? "released" (session-send pj-session pj-root 'release))
        "projections: release arrived after the unresolved projection chain")
(define pj-label-value (session-await pj-session pj-label))
(expect (equal? "alice" pj-label-value) "projections: pipelined untag->index reached the label")
;; The source answer settled while the projection pumped the loop; awaiting it
;; now must still resolve from the vow's recorded state.
(define pj-full (session-await pj-session pj-made))
(expect (and (tagged-arg? pj-full) (equal? "task" (tagged-arg-tag pj-full)))
        "projections: the late source await still settled to the tagged row")

(session-close! pj-session)
(define pj-host-result (channel-get pj-ch))
(when (exn? pj-host-result) (raise pj-host-result))
(expect (eq? 'served pj-host-result) "projections: host served to a clean close")
(server-close! pj-server)
(pj-trace-uninstall)

(printf "racket zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles\n")

;; ── Unawaited break + a real disconnect ───────────────────────────────────────
;; Two failure contracts over a real socket. First: an unawaited
;; `session-send-promise` whose reply breaks stays silent — no listener means the
;; broken vow crashes nothing, and the connection keeps answering. Second: a
;; partner that hangs up mid-question settles the pending `session-send` with a
;; typed GLOWCAP_ERR_CLOSED failure instead of hanging it forever.
(define ub-server (listen "127.0.0.1" 0))
(define ub-ready (make-semaphore 0))
(define ub-boom-seen (make-semaphore 0))
(define ub-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept ub-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(boom) (semaphore-post ub-boom-seen) (error "kaboom: refused")]
                        [(ok) (sym "fine")])))
       (semaphore-post ub-ready)
       (session-serve hsession)))))
(define ub-session (open-test-session (tcp-locator "127.0.0.1" (server-port ub-server))))
(semaphore-wait ub-ready)
(define ub-cap (session-fetch ub-session "svc"))
;; Fire the failing verb and never await it. No later operation exists yet:
;; creation itself must flush the deliver and let the server observe it.
(void (session-send-promise ub-session ub-cap 'boom))
(semaphore-wait ub-boom-seen)
(expect (equal? (sym "fine") (session-send ub-session ub-cap 'ok))
        "unawaited: a later call still settles after an unawaited break")
(session-close! ub-session)
(server-close! ub-server)

;; Real disconnect: both ends are high-level; a sniffing relay between them
;; drops the wire the moment the `hang` deliver crosses it, so the client's
;; question is pending when the transport dies and can never be answered.
(define dcs-server (listen "127.0.0.1" 0))
(define dcs-ready (make-semaphore 0))
(define dcs-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept dcs-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(hang) (sym "never")])))
       (semaphore-post dcs-ready)
       (session-serve hsession)))))
(define-values (dcs-relay dcs-relay-port)
  (start-sniffing-relay (server-port dcs-server)
                        (lambda (chunk) (if (regexp-match? #rx#"hang" chunk) 'close #f))))
(define dcs-session (open-test-session (tcp-locator "127.0.0.1" dcs-relay-port)))
(semaphore-wait dcs-ready)
(define dcs-cap (session-fetch dcs-session "svc"))
(define dcs-err
  (with-handlers ([exn:fail:glowcap? (lambda (e) e)])
    (session-send dcs-session dcs-cap 'hang)
    #f))
(expect (and dcs-err (= ERR-CLOSED (exn:fail:glowcap-code dcs-err)))
        "disconnect: the pending send failed typed ERR-CLOSED, never hung")
(session-close! dcs-session)
(void (sync/timeout 2 (thread-dead-evt dcs-host)))
(tcp-close dcs-relay)
(server-close! dcs-server)

(printf "racket zig-smoke OK: an unawaited send progresses silently, and a real disconnect fails a pending send typed\n")
