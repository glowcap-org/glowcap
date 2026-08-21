#lang racket/base
;; One independently loadable family from the Racket binding dogfood.

(require net/base64
         (only-in ffi/unsafe ctype-sizeof)
         racket/random
         racket/runtime-path
         "../../pancake.rkt"
         "../../pancake-tcp.rkt"
         "../../pancake-inproc.rkt"
         "../../pancake-onion.rkt"
         "../../pancake-iroh.rkt"
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
;; typed exn:fail:pancake carrying PANCAKE_ERR_BROKEN; and a failed fetch
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

;; A partner break is a typed pancake failure carrying PANCAKE_ERR_BROKEN.
(define cp-svc (session-fetch cp-session "svc"))
(define cp-broken
  (with-handlers ([exn:fail:pancake? values])
    (session-send cp-session cp-svc 'boom)
    'no-error))
(expect (exn:fail:pancake? cp-broken) "break: session-send raised exn:fail:pancake")
(expect (equal? ERR-BROKEN (exn:fail:pancake-code cp-broken)) "break: code is PANCAKE_ERR_BROKEN")
(expect (regexp-match? #rx"deliberate failure" (exn-message cp-broken))
        "break: the partner's own diagnostic crossed the wire")

;; A fetch of an unpublished name breaks too, and session-fetch re-raises the typed
;; failure untouched instead of flattening it to a generic exn:fail.
(define cp-missing
  (with-handlers ([exn:fail:pancake? values])
    (session-fetch cp-session "no-such-name")
    'no-error))
(expect (exn:fail:pancake? cp-missing) "fetch: an unknown name raised exn:fail:pancake")
(expect (equal? ERR-BROKEN (exn:fail:pancake-code cp-missing)) "fetch: code is PANCAKE_ERR_BROKEN")

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
;; *unresolved* create answer and the four delivers travel as one batch on the
;; settling `session-send`'s pump. The board's `create` spawns a fresh task
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
                        [(create name) (session-spawn hsession ^task)])))
       (semaphore-post pl-ready)
       (session-serve hsession)
       (channel-put pl-ch 'served)))))

(define pl-session (open-test-session (tcp-locator "127.0.0.1" (server-port pl-server))))
(semaphore-wait pl-ready)
(define pl-root (session-fetch pl-session "root"))
;; The four verbs leave together: none waits for create's reply, and assign /
;; complete / status target the create answer directly.
(define pl-task (session-send-promise pl-session pl-root 'create "benchmark"))
(void (session-send-promise pl-session pl-task 'assign "alice"))
(void (session-send-promise pl-session pl-task 'complete))
(define pl-status (session-send pl-session pl-task 'status))
(expect (equal? "done" pl-status) "pipelining: the chained status settled to done")

(session-close! pl-session)
(define pl-host-result (channel-get pl-ch))
(when (exn? pl-host-result) (raise pl-host-result))
(expect (eq? 'served pl-host-result) "pipelining: host served to a clean close")
(server-close! pl-server)

(printf "racket zig-smoke OK: promise pipelining drives create->assign->complete->status as one batch\n")

;; ── Promise-pipeline saturation stays typed and terminal ─────────────────────
;; A queue cap of one admits the first call aimed at an unresolved answer and
;; refuses the second. Both calls travel in the same feed batch, before the
;; create behavior can settle its answer. The refusal must remain the Session's
;; one terminal result through serve and every close observer.
(define qs-host (make-fresh-host))
(host-set-session-limits! qs-host 0 1)
(define qs-server (listen "127.0.0.1" 0 #:host qs-host))
(define qs-ready (make-semaphore 0))
(define qs-parked (box #f))
(define qs-result (make-channel))
(define qs-server-thread
  (thread
   (lambda ()
     (define hsession (accept qs-server))
     (host-publish-giftable
      (session-host hsession) "root"
      (lambda (method . _args)
        (unless (eq? method 'create) (error 'queue-saturation "unexpected method"))
        (define pair (host-defer-turn (session-host hsession)))
        (set-box! qs-parked pair)
        (void)))
     (semaphore-post qs-ready)
     (define serve-failure
       (with-handlers ([exn:fail:pancake? values])
         (session-serve hsession)
         'served))
     (define close-failure
       (with-handlers ([exn:fail:pancake? values])
         (session-close! hsession)
         'closed))
     (define repeated-close-failure
       (with-handlers ([exn:fail:pancake? values])
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
(let await-deferred-answer ()
  (unless (unbox qs-parked) (sleep 0.001) (await-deferred-answer)))
(void (session-send-promise qs-session qs-task 'assign "first"))
(define qs-saturated
  (session-send-promise qs-session qs-task 'assign "saturated"))
(define qs-client-failure
  (with-handlers ([exn:fail:pancake? values])
    (session-await qs-session qs-saturated)
    'settled))
(define qs-observed (sync/timeout 10 qs-result))
(expect qs-observed "queue saturation: exporter serve did not terminate")
(define qs-serve-failure (list-ref qs-observed 0))
(define qs-close-failure (list-ref qs-observed 1))
(define qs-repeated-close-failure (list-ref qs-observed 2))
(define qs-abort
  (and (exn:fail:pancake? qs-serve-failure)
       (exn:fail:pancake-abort qs-serve-failure)))
(expect (and (exn:fail:pancake? qs-client-failure)
             (= ERR-CLOSED (exn:fail:pancake-code qs-client-failure))
             (exn:fail:pancake? qs-serve-failure)
             (= ERR-SESSION (exn:fail:pancake-code qs-serve-failure))
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
(define pj-server (listen "127.0.0.1" 0 #:captp-version 'next))
(define pj-ready (make-semaphore 0))
(define pj-ch (make-channel))
(define pj-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put pj-ch e))])
       (define hsession (accept pj-server))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(make label) (tagged-arg "task" (list (list "assigned" label 7)))])))
       (semaphore-post pj-ready)
       (session-serve hsession)
       (channel-put pj-ch 'served)))))

(define pj-session (open-test-session (tcp-locator "127.0.0.1" (server-port pj-server))
                            #:captp-version 'next))
(semaphore-wait pj-ready)
(define pj-root (session-fetch pj-session "root"))
;; Neither projection waits for make's reply: they ride the unresolved make
;; answer and the whole chain leaves on one pump.
(define pj-made (session-send-promise pj-session pj-root 'make "alice"))
(define pj-label (session-await pj-session (session-index pj-session (session-untag pj-session pj-made "task") 1)))
(expect (equal? "alice" pj-label) "projections: pipelined untag->index reached the label")
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

(printf "racket zig-smoke OK: pipelined projections untag->index reach a field, and a late source await still settles\n")

;; ── Unawaited break + a real disconnect ───────────────────────────────────────
;; Two failure contracts over a real socket. First: an unawaited
;; `session-send-promise` whose reply breaks stays silent — no listener means the
;; broken vow crashes nothing, and the connection keeps answering. Second: a
;; partner that hangs up mid-question settles the pending `session-send` with a
;; typed PANCAKE_ERR_CLOSED failure instead of hanging it forever.
(define ub-server (listen "127.0.0.1" 0))
(define ub-ready (make-semaphore 0))
(define ub-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
       (define hsession (accept ub-server))
       (session-publish hsession "svc"
                     (lambda (bcom)
                       (methods
                        [(boom) (error "kaboom: refused")]
                        [(ok) (sym "fine")])))
       (semaphore-post ub-ready)
       (session-serve hsession)))))
(define ub-session (open-test-session (tcp-locator "127.0.0.1" (server-port ub-server))))
(semaphore-wait ub-ready)
(define ub-cap (session-fetch ub-session "svc"))
;; Fire the failing verb and never await it; the break arrives while the next
;; call pumps and must stay silent.
(void (session-send-promise ub-session ub-cap 'boom))
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
  (with-handlers ([exn:fail:pancake? (lambda (e) e)])
    (session-send dcs-session dcs-cap 'hang)
    #f))
(expect (and dcs-err (= ERR-CLOSED (exn:fail:pancake-code dcs-err)))
        "disconnect: the pending send failed typed ERR-CLOSED, never hung")
(session-close! dcs-session)
(void (sync/timeout 2 (thread-dead-evt dcs-host)))
(tcp-close dcs-relay)
(server-close! dcs-server)

(printf "racket zig-smoke OK: an unawaited break stays silent, and a real disconnect fails a pending send typed\n")


