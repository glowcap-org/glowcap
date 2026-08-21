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

;; Mint a bare negotiating session for close-lifecycle scenarios. The helper
;; deliberately leaves the session pending so Host shutdown owns the outcome.
(define (open-pending-dialed! m)
  (call-with-locator-view (locator "tcp" "pending-session" (hash) 'boolean-false)
    (lambda (view)
      (call-with-host m
        (lambda ()
          (define-values (rc _session)
            (pancake_host_session_open_dialed_locator (host-ptr m) view))
          (check/host rc))))))

;; ── Mid-turn close defers handle release ─────────────────────────────────────
;; A behavior that calls `session-close!` inside its own *wire* turn must not
;; free the native session while the trampoline frame is still on the stack. Local
;; vat turns do not set `inside-turn?` (they never enter the C latch); the park
;; is for the hosted trampoline path. Closing the transport drops the partner
;; before the reply can settle on the wire — the proof here is the park count
;; observed *during* the turn (1), not a far reply.
(define mc-server (listen "127.0.0.1" 0))
(define mc-ready (make-semaphore 0))
(define mc-during (make-channel))
(define mc-ch (make-channel))
(define mc-acceptor
  (thread
   (lambda ()
     (define hsession (accept mc-server))
     (session-publish hsession "svc"
                   (lambda (_bcom)
                     (methods
                      [(die)
                       (session-close! hsession)
                       ;; Native intent is already recorded; only handle release
                       ;; remains parked until this trampoline frame returns.
                       (channel-put mc-during
                                    (host-pending-release-count (session-host hsession)))
                       (sym "closing")])))
     (semaphore-post mc-ready)
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put mc-ch e))])
       (session-serve hsession)
       (channel-put mc-ch 'served)))))

(define mc-session (open-test-session (tcp-locator "127.0.0.1" (server-port mc-server))))
(semaphore-wait mc-ready)
(define mc-svc (session-fetch mc-session "svc"))
;; Drive the deliver without awaiting a reply: closing the exporter mid-turn
;; drops the wire before a settle can land. A bounded thread races the send.
(define mc-client
  (thread
   (lambda ()
     (with-handlers ([exn:fail:pancake? void])
       (session-send mc-session mc-svc 'die)))))
(define mc-parked (sync/timeout 10 mc-during))
(expect (equal? 1 mc-parked)
        (format "mid-turn-close: release parked during the trampoline turn (got ~a)" mc-parked))
(thread-wait mc-client)
(session-close! mc-session)
(define mc-host-result (sync/timeout 10 mc-ch))
(when (exn? mc-host-result) (raise mc-host-result))
(server-close! mc-server)

(printf "racket zig-smoke OK: callback close records native intent and defers handle release\n")

;; Host close records its native admission barrier under the callback latch.
;; Racket defers only waiting and handle release until the feed unwinds, then
;; clears the Host's strong callback/session tables.
(define hr-server (listen "127.0.0.1" 0))
(define hr-ready (make-semaphore 0))
(define hr-during (make-channel))
(define hr-state (make-channel))
(define hr-acceptor
  (thread
   (lambda ()
     (define hsession (accept hr-server))
     (define sibling (accept hr-server))
     (define m (session-host hsession))
     (session-publish hsession "svc"
                      (lambda (_bcom)
                        (methods
                         [(release-host)
                          (host-close! m)
                          (channel-put hr-during
                                       (list (unbox (host-released? m))
                                             (host-pending-release-count m)))
                          (sym "closing")])))
     (semaphore-post hr-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve hsession))
     (channel-put hr-state
                  (list (unbox (host-released? m))
                        (hash-count (host-keep m))
                        (hash-count (host-sessions m)))))))
(define hr-session (open-test-session (tcp-locator "127.0.0.1" (server-port hr-server))))
(define hr-sibling (open-test-session (tcp-locator "127.0.0.1" (server-port hr-server))))
(semaphore-wait hr-ready)
(define hr-svc (session-fetch hr-session "svc"))
(define hr-client
  (thread
   (lambda ()
     (with-handlers ([exn:fail:pancake? void])
       (session-send hr-session hr-svc 'release-host)))))
(expect (equal? '(#f 1) (sync/timeout 10 hr-during))
        "mid-turn Host close records intent and parks one handle-release barrier")
(thread-wait hr-client)
(define hr-final (sync/timeout 10 hr-state))
(expect (equal? '(#t 0 0) hr-final)
        (format "terminal host release clears retained state (got ~a)" hr-final))
(session-close! hr-session)
(session-close! hr-sibling)
(server-close! hr-server)

(printf "racket zig-smoke OK: callback Host close records intent then clears retained state\n")

;; Two explicit releases can both observe a live wrapper before either acquires
;; the host lock. Terminal state must therefore be checked after the wait, not
;; only before it: the second caller is an idempotent no-op, never a second
;; native release of the same pointer.
(define rr-host (make-fresh-host))
(define rr-started (make-semaphore 0))
(define rr-results (make-channel))
(semaphore-wait (host-lock rr-host))
(for ([i (in-range 2)])
  (thread
   (lambda ()
     (semaphore-post rr-started)
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put rr-results e))])
       (host-close! rr-host)
       (channel-put rr-results 'released)))))
(semaphore-wait rr-started)
(semaphore-wait rr-started)
;; Let both green threads reach the held lock before admitting either one.
(sleep 0)
(semaphore-post (host-lock rr-host))
(define rr-first (sync/timeout 10 rr-results))
(define rr-second (sync/timeout 10 rr-results))
(when (exn? rr-first) (raise rr-first))
(when (exn? rr-second) (raise rr-second))
(expect (and (eq? rr-first 'released)
             (eq? rr-second 'released)
             (unbox (host-released? rr-host)))
        "concurrent Host release crosses native teardown exactly once")

(printf "racket zig-smoke OK: concurrent Host release is serialized and idempotent\n")

;; A repeated close is not merely an idempotent wrapper call: every request
;; reaches the one native barrier. Hold FINISH open with a negotiating session,
;; kill the first public waiter, then prove a concurrent CANCEL still escalates
;; the retained worker and every surviving caller joins the terminal result.
(define re-host (make-fresh-host))
(open-pending-dialed! re-host)
(define re-results (make-channel))
(define re-finish-thread
  (thread
 (lambda ()
   (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put re-results e))])
     (host-close! re-host #:pending 'finish #:grace-ms #f)
     (channel-put re-results 'finished)))))
(let await-finishing ([remaining 1000])
  (when (zero? remaining) (fail "unbounded Host finish did not enter FINISHING"))
  (define state
    (call-with-host
     re-host
     (lambda ()
       (define-values (rc lifecycle)
         (pancake_host_close_progress (host-ptr re-host) (monotonic-ms)))
       (check/host rc)
       lifecycle)))
  (unless (= state LIFECYCLE-FINISHING)
    (sleep 0.001)
    (await-finishing (sub1 remaining))))
(define re-join-entered (make-semaphore 0))
(define re-join-thread
  (thread
   (lambda ()
     (semaphore-post re-join-entered)
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put re-results e))])
       (host-close! re-host #:pending 'finish #:grace-ms #f)
       (channel-put re-results 'joined)))))
(semaphore-wait re-join-entered)
;; Give the second caller a turn to enter the already-installed barrier, then
;; terminate only the caller that originally requested FINISH.
(sleep 0)
(kill-thread re-finish-thread)
(thread-wait re-finish-thread)
(define re-cancel-thread
  (thread
 (lambda ()
   (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put re-results e))])
     (host-close! re-host #:pending 'cancel)
     (channel-put re-results 'cancelled)))))
(define re-first (sync/timeout 10 re-results))
(define re-second (sync/timeout 10 re-results))
(when (exn? re-first) (raise re-first))
(when (exn? re-second) (raise re-second))
(expect (and (memq re-first '(joined cancelled))
             (memq re-second '(joined cancelled))
             (not (eq? re-first re-second))
             (unbox (host-released? re-host)))
        "killing the first Host close waiter does not stop the shared close worker")

(printf "racket zig-smoke OK: Host close worker outlives the first waiter\n")

;; A finish close whose finite grace expires reports ERR-TIMEOUT and still
;; crosses terminal release. The outcome is retained: a repeated close on the
;; released Host re-observes the same timeout instead of silently succeeding,
;; the contract the TypeScript, Rust, and Python Hosts hold.
(define gt-host (make-fresh-host))
(open-pending-dialed! gt-host)
(define gt-first
  (with-handlers ([exn:fail:pancake? values])
    (host-close! gt-host #:pending 'finish #:grace-ms 50)
    'completed))
(expect (and (exn:fail:pancake? gt-first)
             (= ERR-TIMEOUT (exn:fail:pancake-code gt-first))
             (unbox (host-released? gt-host)))
        "finish grace expiry surfaces ERR-TIMEOUT after terminal release")
(define gt-second
  (with-handlers ([exn:fail:pancake? values])
    (host-close! gt-host)
    'completed))
(expect (and (exn:fail:pancake? gt-second)
             (= ERR-TIMEOUT (exn:fail:pancake-code gt-second)))
        "a repeated close re-observes the retained timeout outcome")

(printf "racket zig-smoke OK: repeated Host close re-observes the finish timeout\n")

;; runtime-close! is the shutdown barrier for the Host the Runtime created:
;; after it returns, that Host is released, the session it yielded is retired,
;; and a repeated close joins the same terminal outcome.
(define rb-server (listen "127.0.0.1" 0))
(define rb-acceptor
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (session-serve (accept rb-server))))))
(define rb-runtime (open-runtime #:providers (list (tcp-provider))))
(define rb-session
  (runtime-connect rb-runtime
                   (tcp-locator "127.0.0.1" (server-port rb-server))))
(define rb-host (runtime-host rb-runtime))
(runtime-close! rb-runtime)
(expect (unbox (host-released? rb-host))
        "runtime-close! returned before its Host crossed terminal release")
(expect (session-released? rb-session)
        "runtime-close! returned before its dialed session was retired")
(runtime-close! rb-runtime)
(thread-wait rb-acceptor)
(server-close! rb-server)

(printf "racket zig-smoke OK: runtime-close! is the Host shutdown barrier\n")

;; The loop-tier counterpart of the byte-fed grace-timeout scenario above: a
;; dial still negotiating against a silent TCP partner is admitted pending
;; work, so a finish close whose finite grace expires reports ERR-TIMEOUT
;; through the loop close barrier and still crosses terminal release. The
;; expiry takes effect only inside a `pancake_driver_step`, so this also
;; exercises the loop close driver's deadline-timer park.
(define lg-listener (tcp-listen 0 4 #t "127.0.0.1"))
(define lg-port
  (let-values ([(_host port _peer-host _peer-port)
                (tcp-addresses lg-listener #t)])
    port))
(define lg-runtime (open-runtime #:providers (list (tcp-provider))))
(define lg-dial-result (make-channel))
(define lg-dial-thread
  (thread
   (lambda ()
     (channel-put lg-dial-result
                  (with-handlers ([exn? values])
                    (runtime-connect lg-runtime
                                     (tcp-locator "127.0.0.1" lg-port))
                    'connected)))))
;; Accepting proves the dial reached TCP connect, so it is admitted pending
;; work before the close begins; the accepted ports then stay silent, so the
;; CapTP handshake can never finish inside the grace.
(define-values (lg-in lg-out) (tcp-accept lg-listener))
(define lg-first
  (with-handlers ([exn:fail:pancake? values])
    (host-close! (runtime-host lg-runtime) #:pending 'finish #:grace-ms 50)
    'completed))
(expect (and (exn:fail:pancake? lg-first)
             (= ERR-TIMEOUT (exn:fail:pancake-code lg-first))
             (unbox (host-released? (runtime-host lg-runtime))))
        "loop finish grace expiry surfaces ERR-TIMEOUT after terminal release")
(expect (exn? (sync/timeout 10 lg-dial-result))
        "the expiring loop close failed the admitted dial")
(thread-wait lg-dial-thread)
(close-input-port lg-in)
(close-output-port lg-out)
(tcp-close lg-listener)

(printf "racket zig-smoke OK: loop finish close reports its grace timeout\n")

;; An ordinary dial has no close driver to supply a timer. Accept TCP and then
;; stay silent: the binding's one progress clock must wake at HostRuntime's
;; handshake deadline and project the native ERR-TIMEOUT event.
(define hd-listener (tcp-listen 0 4 #t "127.0.0.1"))
(define hd-port
  (let-values ([(_host port _peer-host _peer-port)
                (tcp-addresses hd-listener #t)])
    port))
(define hd-runtime
  (open-runtime #:providers (list (tcp-provider))
                #:handshake-timeout-ms 50))
(define hd-result (make-channel))
(define hd-thread
  (thread
   (lambda ()
     (channel-put hd-result
                  (with-handlers ([exn? values])
                    (runtime-connect hd-runtime
                                     (tcp-locator "127.0.0.1" hd-port)))))))
(define-values (hd-in hd-out) (tcp-accept hd-listener))
(define hd-outcome (sync/timeout 2 hd-result))
(expect (and (exn:fail:pancake? hd-outcome)
             (= ERR-TIMEOUT (exn:fail:pancake-code hd-outcome)))
        "a silent loop dial did not reach its native handshake deadline")
(thread-wait hd-thread)
(runtime-close! hd-runtime)
(close-input-port hd-in)
(close-output-port hd-out)
(tcp-close hd-listener)

(printf "racket zig-smoke OK: a silent loop dial reaches pancake's native handshake deadline\n")

;; Session close has the same ownership contract. A negotiating byte-fed
;; session keeps unbounded FINISH pending; killing the first waiter must not
;; strand the worker that a later CANCEL needs to reach physical release.
(define sc-host (make-fresh-host))
(define sc-session
  (open-dialed-over
   sc-host
   "tcp"
   "pending-session-close"
   (async-transport (lambda (_frame) (void)) void (lambda (_wake) eof) void)))
(define sc-results (make-channel))
(define sc-first
  (thread
   (lambda ()
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put sc-results e))])
       (session-close! sc-session #:pending 'finish #:grace-ms #f)
       (channel-put sc-results 'first)))))
(let await-session-worker ([remaining 1000])
  (when (zero? remaining) (fail "unbounded Session finish did not install its worker"))
  (unless (hash-ref session-close-active sc-session #f)
    (sleep 0.001)
    (await-session-worker (sub1 remaining))))
(define sc-join-entered (make-semaphore 0))
(define sc-join
  (thread
   (lambda ()
     (semaphore-post sc-join-entered)
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put sc-results e))])
       (session-close! sc-session #:pending 'finish #:grace-ms #f)
       (channel-put sc-results 'joined)))))
(semaphore-wait sc-join-entered)
(sleep 0)
(kill-thread sc-first)
(thread-wait sc-first)
(define sc-cancel
  (thread
   (lambda ()
     (with-handlers ([(lambda (_e) #t) (lambda (e) (channel-put sc-results e))])
       (session-close! sc-session #:pending 'cancel)
       (channel-put sc-results 'cancelled)))))
(define sc-one (sync/timeout 10 sc-results))
(define sc-two (sync/timeout 10 sc-results))
(when (exn? sc-one) (raise sc-one))
(when (exn? sc-two) (raise sc-two))
(expect (and (memq sc-one '(joined cancelled))
             (memq sc-two '(joined cancelled))
             (not (eq? sc-one sc-two))
             (session-released? sc-session))
        "killing the first Session close waiter does not stop the shared close worker")
(host-close! sc-host)

(printf "racket zig-smoke OK: Session close worker outlives the first waiter\n")

;; A FLUSH runs after the Host lock has released and may have no immediate
;; caller of its own. Inject one exact transport exception through a real CapTP
;; pair: the tell that provokes it, the concurrent serve loop, and repeated
;; close must all receive that same object, after the byte channel has retired
;; exactly once. One broken Session must not escape through the Host drain.
(define wf-server (listen "127.0.0.1" 0))
(define wf-ready (make-semaphore 0))
(define wf-server-result (make-channel))
(define wf-server-thread
  (thread
   (lambda ()
     (define c (accept wf-server))
     (session-publish c "svc" (lambda (bcom) (methods [(ping) 'alive])))
     (semaphore-post wf-ready)
     (channel-put wf-server-result
                  (with-handlers ([(lambda (_) #t) values])
                    (session-serve c)
                    'closed)))))
(define-values (wf-in wf-out)
  (tcp-connect "127.0.0.1" (server-port wf-server)))
(define wf-base (port-transport wf-in wf-out))
(define wf-fail-writes? (box #f))
(define wf-close-count (box 0))
(define wf-first-failure
  (exn:fail "injected exact FLUSH failure" (current-continuation-marks)))
(define wf-transport
  (async-transport
   (lambda (frame)
     (if (unbox wf-fail-writes?)
         (raise wf-first-failure)
         ((async-transport-write-frame! wf-base) frame)))
   (async-transport-flush! wf-base)
   (async-transport-read-some! wf-base)
   (lambda ()
     (set-box! wf-close-count (add1 (unbox wf-close-count)))
     ((async-transport-close! wf-base)))))
(define wf-host (make-fresh-host))
(define wf-session
  (establish-dialed-locator-session wf-host (server-locator wf-server) wf-transport))
(semaphore-wait wf-ready)
(define wf-client-result (make-channel))
(define wf-client-thread
  (thread
   (lambda ()
     (channel-put wf-client-result
                  (with-handlers ([(lambda (_) #t) values])
                    (session-serve wf-session)
                    'closed)))))
(define wf-svc (session-fetch wf-session "svc"))
(set-box! wf-fail-writes? #t)
(define wf-tell-failure
  (with-handlers ([(lambda (_) #t) values])
    (session-tell wf-session wf-svc 'ping)
    'no-error))
(define wf-serve-failure (sync/timeout 10 wf-client-result))
(define wf-close-failure
  (with-handlers ([(lambda (_) #t) values])
    (session-close! wf-session)
    'no-error))
(expect (eq? wf-first-failure wf-tell-failure)
        "wire failure: tell lost the exact FLUSH exception")
(expect (eq? wf-first-failure wf-serve-failure)
        "wire failure: serve lost the exact FLUSH exception")
(expect (eq? wf-first-failure wf-close-failure)
        "wire failure: close lost the exact FLUSH exception")
(expect (= 1 (unbox wf-close-count))
        "wire failure: terminal observers ran before one physical retirement")
(thread-wait wf-client-thread)
(define wf-server-outcome (sync/timeout 10 wf-server-result))
(expect (eq? 'closed wf-server-outcome)
        "wire failure: the peer did not retire cleanly after the broken Session closed")
(thread-wait wf-server-thread)
(host-close! wf-host)
(server-close! wf-server)

(printf "racket zig-smoke OK: Session tell, serve, and close retain the exact first FLUSH failure\n")

