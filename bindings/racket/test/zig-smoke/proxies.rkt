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

;; ── Object-capability forwarding proxies over the wire (ADR-0064) ─────────────
;; The client spawns a local tool and passes it as an argument to the host, which
;; sees a far reference and wraps it in a caretaker and an attenuator, handing the
;; proxies back. A call through the caretaker proxy forwards across the host back
;; to the client's tool (the far deferred-answer path) and settles the caller's
;; answer; the attenuator passes only its allow-listed verb; and a revoke breaks
;; every later call.
(define (^tool bcom)
  (methods
   [(add n) (+ n 1)]
   [(get) 7]))

(define mb-server (listen "127.0.0.1" 0))
(define mb-ready (make-semaphore 0))
(define mb-ch (make-channel))
(define mb-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put mb-ch e))])
       (define hsession (accept mb-server))
       ;; The caretaker the host hands out, stashed so `revoke` can sever it.
       (define proxy-box (box #f))
       (session-publish hsession "root"
                     (lambda (bcom)
                       (methods
                        [(make-proxy tool)
                         (define proxy (session-caretaker hsession tool))
                         (set-box! proxy-box proxy)
                         proxy]
                        [(make-readonly tool) (session-attenuate hsession tool '("get"))]
                        [(revoke) (session-revoke! hsession (unbox proxy-box)) "revoked"])))
       (semaphore-post mb-ready)
       (session-serve hsession)
       (channel-put mb-ch 'served)))))

(define mb-session (open-test-session (tcp-locator "127.0.0.1" (server-port mb-server))))
(semaphore-wait mb-ready)
(define mb-tool (session-spawn mb-session ^tool))
(define mb-root (session-fetch mb-session "root"))

;; Live caretaker: a call forwards across the host to the client's far tool.
(define mb-proxy (session-send mb-session mb-root 'make-proxy mb-tool))
(expect mb-proxy "proxy: the host returned a caretaker proxy")
(expect (= 42 (session-send mb-session mb-proxy 'add 41)) "proxy: caretaker forwards to the far tool")

;; Attenuator: the allow-listed verb forwards; any other breaks.
(define mb-ro (session-send mb-session mb-root 'make-readonly mb-tool))
(expect (= 7 (session-send mb-session mb-ro 'get)) "proxy: attenuator forwards an allowed verb")
(define mb-denied
  (with-handlers ([exn:fail:glowcap? (lambda (e) e)])
    (session-send mb-session mb-ro 'add 1) #f))
(expect (and (exn:fail:glowcap? mb-denied)
             (regexp-match? #rx"Attenuated" (exn-message mb-denied)))
        "proxy: an out-of-list verb breaks Attenuated")

;; Revoke: every later call through the proxy breaks.
(void (session-send mb-session mb-root 'revoke))
(define mb-severed
  (with-handlers ([exn:fail:glowcap? (lambda (e) e)])
    (session-send mb-session mb-proxy 'add 1) #f))
(expect (and (exn:fail:glowcap? mb-severed)
             (regexp-match? #rx"Revoked" (exn-message mb-severed)))
        "proxy: a revoked proxy breaks Revoked")

(session-close! mb-session)
(define mb-host-result (channel-get mb-ch))
(when (exn? mb-host-result) (raise mb-host-result))
(expect (eq? 'served mb-host-result) "proxy: host served to a clean close")
(server-close! mb-server)

(printf "racket zig-smoke OK: forwarding proxies forward, attenuate, and revoke over the wire\n")

;; ── A forwarding proxy answers its host's own local call (ADR-0064) ────────────
;; The wart ADR-0064 closes: a caretaker proxy is an ordinary spawned actor, so
;; its own host calls it locally exactly as a partner calls it over the wire. A
;; caretaker over a *local* tool answers a local send; a caretaker over a *far*
;; tool forwards across the wire and the local send still settles; and a revoke
;; breaks the local call too, no second-class behavior on the hosting side.
(define (^ping bcom) (methods [(ping) 99]))
(define (^doubler bcom) (methods [(double n) (* n 2)]))

(define lc-server (listen "127.0.0.1" 0))
(define lc-ready (make-semaphore 0))
(define lc-ch (make-channel))
(define lc-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put lc-ch e))])
       (define hsession (accept lc-server))
       (session-publish hsession "tool" ^ping)
       (semaphore-post lc-ready)
       (session-serve hsession)
       (channel-put lc-ch 'served)))))

(define lc-session (open-test-session (tcp-locator "127.0.0.1" (server-port lc-server))))
(semaphore-wait lc-ready)

;; A caretaker over a local tool, called locally by its own host.
(define lc-local (session-spawn lc-session ^doubler))
(define lc-care (session-caretaker lc-session lc-local))
(expect (= 42 (session-send lc-session lc-care 'double 21))
        "local-call: a local proxy answers a local call")

;; A caretaker over a far tool, called locally: the proxy forwards across the wire
;; and the local send still settles on the partner's reply.
(define lc-far (session-fetch lc-session "tool"))
(define lc-care-far (session-caretaker lc-session lc-far))
(expect (= 99 (session-send lc-session lc-care-far 'ping))
        "local-call: a local call over a far tool settles")

;; Revoke severs the local call exactly as it severs a partner's.
(session-revoke! lc-session lc-care)
(define lc-severed
  (with-handlers ([exn:fail:glowcap? (lambda (e) e)])
    (session-send lc-session lc-care 'double 1) #f))
(expect (and (exn:fail:glowcap? lc-severed)
             (regexp-match? #rx"Revoked" (exn-message lc-severed)))
        "local-call: revoke breaks a local call too")

(session-close! lc-session)
(define lc-host-result (channel-get lc-ch))
(when (exn? lc-host-result) (raise lc-host-result))
(server-close! lc-server)

(printf "racket zig-smoke OK: a forwarding proxy answers its host's own local call (local and far target)\n")

;; ── The callback latch crosses the binding ────────────────────────────────────
;; A behavior that reaches for a host-driving verb mid-turn (session-fetch, here)
;; is refused by the C tier before it can block, the refusal surfaces as the
;; method's own raise, and the answer breaks with it — the turn neither
;; deadlocks nor corrupts the host. This is the loud edge of the binding rule
;; that a handler must not drive (or block on) the host inside its own turn.
;; The connection stays fully usable afterwards.
(define rt-server (listen "127.0.0.1" 0))
(define rt-ready (make-semaphore 0))
(define rt-ch (make-channel))
(define rt-host
  (thread
   (lambda ()
     (define hsession (accept rt-server))
     (session-publish hsession "svc"
                   (lambda (bcom)
                     (methods
                      [(reenter) (session-fetch hsession "nested")]
                      [(ping) (sym "pong")])))
     (semaphore-post rt-ready)
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put rt-ch e))])
       (session-serve hsession)
       (channel-put rt-ch 'served)))))

(define rt-session (open-test-session (tcp-locator "127.0.0.1" (server-port rt-server))))
(semaphore-wait rt-ready)
(define rt-cap (session-fetch rt-session "svc"))
(define rt-broken
  (with-handlers ([exn:fail:glowcap? values])
    (session-send rt-session rt-cap 'reenter) #f))
(expect (exn:fail:glowcap? rt-broken)
        "reentry: a mid-turn driving verb breaks the answer")
;; The turn unwound cleanly: the same session still answers.
(expect (equal? (sym "pong") (session-send rt-session rt-cap 'ping))
        "reentry: the connection survives the refused turn")
(session-close! rt-session)
(define rt-host-result (channel-get rt-ch))
(when (exn? rt-host-result) (raise rt-host-result))
(server-close! rt-server)

(printf "racket zig-smoke OK: a behavior's mid-turn driving verb is refused and breaks its own answer\n")


