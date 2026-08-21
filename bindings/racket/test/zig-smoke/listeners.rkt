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

;; ── A rude probe cannot close the listener ────────────────────────────────────
;; A rude TCP probe — connect, say nothing, hang up — is that connection's
;; failure, not the listener's. `accept` completes the keyed handshake, so the
;; probe fails inside the accept; the accept skips it, waits for the next
;; partner, and returns the real client to the caller. Without that isolation
;; one port scan takes a long-lived server down.
(define rp-server (listen "127.0.0.1" 0))
(define rp-ready (make-semaphore 0))
(define rp-host
  (thread
   (lambda ()
     ;; The handler posts `rp-ready` so a regression fails the fetch below
     ;; loudly instead of parking this scene on an unposted semaphore.
     (with-handlers ([(lambda (_) #t) (lambda (_e) (semaphore-post rp-ready))])
       ;; One accept, no retry loop: skipping the probe is `accept`'s own job.
       (define hsession (accept rp-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(ping) (sym "alive")])))
       (semaphore-post rp-ready)
       (with-handlers ([(lambda (_) #t) (lambda (_e) (void))])
         (session-serve hsession))))))
;; The probe: open a socket and immediately hang up.
(define-values (rp-in rp-out) (tcp-connect "127.0.0.1" (server-port rp-server)))
(close-output-port rp-out)
(close-input-port rp-in)
(define rp-session (open-test-session (tcp-locator "127.0.0.1" (server-port rp-server))))
(semaphore-wait rp-ready)
(define rp-cap (session-fetch rp-session "svc"))
(expect (equal? (sym "alive") (session-send rp-session rp-cap 'ping))
        "probe: the listener survived the rude probe and served the next client")
(session-close! rp-session)
(server-close! rp-server)

(printf "racket zig-smoke OK: a rude probe cannot close the listener\n")

;; Host teardown owns the native loop. An accept at the public boundary must
;; wake terminally before native Host state disappears, never retain the place.
(define hc-server (listen "127.0.0.1" 0))
(define hc-started (make-semaphore 0))
(define hc-result (make-channel))
(define hc-accept
  (thread
   (lambda ()
     (semaphore-post hc-started)
     (channel-put
      hc-result
      (with-handlers ([exn? values])
        (accept hc-server)
        'accepted)))))
(semaphore-wait hc-started)
(host-close! (server-host hc-server))
(define hc-terminal (sync/timeout 2 hc-result))
(expect (exn? hc-terminal)
        "Host release: a parked listener accept did not fail promptly")
(thread-wait hc-accept)

(printf "racket zig-smoke OK: Host release stops native listener admission\n")

;; A bare server owns the Host it created, but listener close is not permission
;; to revoke a session already yielded to the application. Retirement waits for
;; that session to leave the Host's authoritative registry, then releases the
;; loop without a second binding-side session table.
(define owned-loop-server (listen "127.0.0.1" 0))
(define owned-loop-host (server-host owned-loop-server))
(define owned-loop-ready (make-semaphore 0))
(define owned-loop-accept
  (thread
   (lambda ()
     (define c (accept owned-loop-server))
     (session-publish c "svc"
                      (lambda (bcom) (methods [(ping) (sym "alive")])) )
     (semaphore-post owned-loop-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve c)))))
(define owned-loop-client
  (open-test-session (tcp-locator "127.0.0.1" (server-port owned-loop-server))))
(semaphore-wait owned-loop-ready)
(server-close! owned-loop-server)
(expect (not (unbox (host-released? owned-loop-host)))
        "bare server close released a yielded session's Host")
(define owned-loop-cap (session-fetch owned-loop-client "svc"))
(expect (equal? (sym "alive")
                (session-send owned-loop-client owned-loop-cap 'ping))
        "bare server close destroyed a yielded session")
(session-close! owned-loop-client)
(thread-wait owned-loop-accept)
(let wait-retired ([attempt 0])
  (when (and (not (unbox (host-released? owned-loop-host))) (< attempt 200))
    (sleep 0.01)
    (wait-retired (add1 attempt))))
(expect (unbox (host-released? owned-loop-host))
        "bare server did not retire its Host after the last yielded session")
(printf "racket zig-smoke OK: bare server retirement waits for yielded sessions\n")

;; A supplied Host is transferred into the native TCP loop, and listener close
;; stops new admission without destroying a session already yielded to the
;; application. The exact wrapper identity is the authority proof.
(define supplied-tcp-host (make-fresh-host))
(define supplied-tcp-server
  (listen "127.0.0.1" 0 #:host supplied-tcp-host))
(expect (eq? supplied-tcp-host (server-host supplied-tcp-server))
        "supplied TCP Host wrapper was not adopted by the driver")
(define supplied-tcp-ready (make-semaphore 0))
(define supplied-tcp-accept
  (thread
   (lambda ()
     (define c (accept supplied-tcp-server))
     (session-publish c "svc"
                      (lambda (bcom) (methods [(ping) (sym "alive")])) )
     (semaphore-post supplied-tcp-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve c)))))
(define supplied-tcp-client
  (open-test-session (tcp-locator "127.0.0.1" (server-port supplied-tcp-server))))
(semaphore-wait supplied-tcp-ready)
(server-close! supplied-tcp-server)
(define supplied-tcp-cap (session-fetch supplied-tcp-client "svc"))
(expect (equal? (sym "alive")
                (session-send supplied-tcp-client supplied-tcp-cap 'ping))
        "TCP listener close destroyed a yielded supplied-Host session")
(session-close! supplied-tcp-client)
(thread-wait supplied-tcp-accept)
(host-close! supplied-tcp-host)
(printf "racket zig-smoke OK: supplied TCP Host adoption preserves yielded sessions\n")

;; Listener ownership is per driver listener: closing the first transport must
;; leave a sibling listener on the same supplied Host able to admit a session.
(define sibling-host (make-fresh-host))
(define sibling-tcp (listen "127.0.0.1" 0 #:host sibling-host))
(define sibling-keyed (listen-keyed-tcp "127.0.0.1" 0 #:host sibling-host))
(server-close! sibling-tcp)
(define sibling-client
  (open-test-session (server-locator sibling-keyed)))
(define sibling-accepted (accept sibling-keyed))
(expect (eq? sibling-host (server-host sibling-keyed))
        "closing one listener changed the sibling Host owner")
(session-close! sibling-accepted)
(session-close! sibling-client)
(server-close! sibling-keyed)
(define sibling-noise (listen-noise-tcp "127.0.0.1" 0 #:host sibling-host))
(expect (equal? (locator-transport (server-locator sibling-noise))
                TRANSPORT-NOISE-TCP)
        "generic server locator lost the noise-tcp profile")
(expect (equal? (parse-locator (server-uri sibling-noise))
                (server-locator sibling-noise))
        "generic server URI drifted from its canonical locator")
(define sibling-noise-client (open-test-session (server-locator sibling-noise)))
(define sibling-noise-accepted (accept sibling-noise))
(expect (eq? sibling-host (server-host sibling-noise))
        "noise listener should adopt the supplied Host")
(session-close! sibling-noise-accepted)
(session-close! sibling-noise-client)
(server-close! sibling-noise)
(host-close! sibling-host)
(printf "racket zig-smoke OK: TCP profiles share one server and Host surface\n")

;; The iroh provider follows the same seam: the supplied Host is adopted before
;; the resident is installed, and the generic driver owns listener close.
(define supplied-iroh-host (make-host (make-bytes 32 19)))
(define supplied-iroh-server
  (listen-iroh (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)
               #:host supplied-iroh-host))
(expect (eq? supplied-iroh-host (iroh-server-host supplied-iroh-server))
        "supplied iroh Host wrapper was not adopted by the driver")
(define supplied-iroh-ready (make-semaphore 0))
(define supplied-iroh-accept
  (thread
   (lambda ()
     (define c (iroh-server-accept supplied-iroh-server))
     (session-publish c "svc"
                      (lambda (bcom) (methods [(ping) (sym "alive")])) )
     (semaphore-post supplied-iroh-ready)
     (with-handlers ([(lambda (_) #t) void]) (session-serve c)))))
(define supplied-iroh-client
  (open-test-session (iroh-server-locator supplied-iroh-server)
           #:provider (iroh-provider
                       (make-iroh-config IROH-REACH-LOCAL-DISCOVERY))))
(semaphore-wait supplied-iroh-ready)
(iroh-server-close! supplied-iroh-server)
(define supplied-iroh-cap (session-fetch supplied-iroh-client "svc"))
(expect (equal? (sym "alive")
                (session-send supplied-iroh-client supplied-iroh-cap 'ping))
        "iroh listener close destroyed a yielded supplied-Host session")
(session-close! supplied-iroh-client)
(thread-wait supplied-iroh-accept)
(host-close! supplied-iroh-host)
(printf "racket zig-smoke OK: supplied iroh Host adoption preserves yielded sessions\n")

;; A wildcard bind is deployment policy, not a dialable locator. Once an
;; explicit advertised host is supplied, a silent first peer consumes one
;; bounded handshake lane and a real peer must still be admitted promptly.
(define wildcard-error
  (with-handlers ([exn:fail:pancake? values])
    (listen "0.0.0.0" 0)
    #f))
(expect (and wildcard-error
             (= ERR-INVALID-ARGUMENT (exn:fail:pancake-code wildcard-error)))
        "native listener admission: a wildcard bind requires an advertised host")
(define ca-server
  (listen "0.0.0.0" 0
          #:advertised-host "127.0.0.1"))
(define ca-ready (make-semaphore 0))
(define ca-host
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (define hsession (accept ca-server))
       (session-publish hsession "svc" (lambda (bcom) (methods [(ping) (sym "alive")])))
       (semaphore-post ca-ready)
       (session-serve hsession)))))
(define-values (ca-silent-in ca-silent-out)
  (tcp-connect "127.0.0.1" (server-port ca-server)))
(define ca-client-ch (make-channel))
(void
 (thread
  (lambda ()
    (channel-put
     ca-client-ch
     (with-handlers ([(lambda (_) #t) values])
       (open-test-session (tcp-locator "127.0.0.1" (server-port ca-server))))))))
(define ca-session (sync/timeout 2 ca-client-ch))
(expect (and ca-session (not (exn? ca-session)))
        "native listener admission: a silent peer parked the next handshake")
(expect (sync/timeout 2 (semaphore-peek-evt ca-ready))
        "native listener admission: the real peer was not published")
(expect (equal? (partner-identity-designator (session-partner-identity ca-session))
                (tcp-address-designator "127.0.0.1" (server-port ca-server)))
        "native listener admission: the signed locator uses explicit reachability")
(define ca-cap (session-fetch ca-session "svc"))
(expect (equal? (sym "alive") (session-send ca-session ca-cap 'ping))
        "native listener admission: the real peer remained usable")
(session-close! ca-session)
(close-output-port ca-silent-out)
(close-input-port ca-silent-in)
(void (sync/timeout 2 (thread-dead-evt ca-host)))
(server-close! ca-server)

(printf "racket zig-smoke OK: native listener admission bypasses a silent peer and wildcard reachability is explicit\n")


