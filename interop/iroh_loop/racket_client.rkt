#lang racket
;; Live iroh scale proof for the Racket binding: many concurrent connections
;; served from one readiness loop (ADR-0057), the Racket sibling of the Zig
;; `zig build iroh-loop` gate.
;;
;; The iroh netlayer has one I/O model — an event-driven readiness loop. This
;; gate proves it through the binding: one `iroh-server` runs a single readiness
;; loop (one green thread parked natively on the endpoint's readiness fd,
;; ADR-0057) and serves every accepted connection's peer from green threads on the
;; one place. Many clients dial it at once, each over its own iroh endpoint, fetch
;; the published greeter, and call it several times. Every reply must come back
;; correct — so the one server loop is provably multiplexing all the connections
;; at once, not serving them one at a time.
;;
;; It exercises the whole loop surface live through the binding: the readiness fd,
;; the records `drain-ready` returns, non-blocking `try-accept`, and
;; `conn-try-read` / `conn-try-write` with their WOULD-BLOCK re-arming. Teardown
;; is non-blocking by construction — no parked read races a release.
;;
;; Needs `racket` plus the iroh ABI companion library (`zig build iroh-abi`); run
;; via `zig build racket-iroh-loop`.

(require "../../bindings/racket/pancake.rkt"
         "../../bindings/racket/pancake-iroh.rkt"
         "../_common/racket/helpers.rkt")

;; Concurrent connections, each served on the one server loop; calls each makes
;; before closing, several turns per connection so the proof is sustained
;; multiplexing, not a single round trip. Mirrors the Zig iroh-loop gate.
(define NUM-CONNS 16)
(define CALLS-PER-CONN 4)
(define GREETING "hello over the iroh loop")

(ignore-port-args "racket-iroh-loop")

;; The published actor: answer `greet` with a static greeting.
(define (greeter bcom)
  (methods [(greet who) GREETING]))

(define server (listen-iroh (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))
(define server-id (iroh-server-node-id server))
(printf "racket-iroh-loop: server endpoint id ~a\n" server-id)

;; Accept every dial, publish this connection's greeter, and serve it in its own
;; green thread, all multiplexed on the server's one readiness loop. The accept
;; loop ends when the server closes (`iroh-server-accept` then raises).
(define served-threads (box '()))
(define accept-thread
  (thread
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) (void))]) ; server closed: stop accepting
       (let loop ()
         (define session (iroh-server-accept server))
         (session-publish session "greeter" greeter)
         (set-box! served-threads
                   (cons (thread (lambda () (session-serve session))) (unbox served-threads)))
         (loop))))))

;; A valid but incomplete outer frame occupies one bounded handshake lane. The
;; clients below must still complete before that lane's timeout expires.
(define silent
  (dial-locator-for-relay
   (format-peer-uri TRANSPORT-IROH server-id)
   IROH-REACH-LOCAL-DISCOVERY))
((byte-channel-write silent) #"1")

;; One client: bind its own iroh endpoint, dial the server by id alone (the
;; local-discovery book resolves it), fetch the greeter, and call it
;; CALLS-PER-CONN times, checking every reply.
(define (client-once)
  ;; Every simulated peer owns a distinct endpoint and Host, so each call opens
  ;; its own Runtime rather than sharing transport identity across clients.
  (define runtime
    (open-runtime
     #:providers (list (iroh-provider
                        (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))))
  (define session
    (runtime-connect runtime (iroh-locator server-id)))
  (dynamic-wind
   void
   (lambda ()
     (define greeter-cap (session-fetch session "greeter"))
     (for ([_ (in-range CALLS-PER-CONN)])
       (define reply (session-send session greeter-cap 'greet "world"))
       (unless (equal? reply GREETING)
         (error 'client (format "wrong reply: ~s" reply)))))
   (lambda ()
     (session-close! session)
     (runtime-close! runtime))))

;; Fan out all clients at once: they share nothing, so the only thing that can
;; serve them all is the one server loop multiplexing.
(define client-results
  (for/list ([_ (in-range NUM-CONNS)])
    (define result (box 'pending))
    (define t (thread (lambda ()
                        (with-handlers ([(lambda (_) #t) (lambda (e) (set-box! result (cons 'error e)))])
                          (client-once)
                          (set-box! result 'ok)))))
    (cons t result)))

(for ([cr client-results]) (thread-wait (car cr)))
((byte-channel-close! silent))

;; Bring the server down so the accept thread ends and no readiness thread
;; outlives the endpoint it watches.
(iroh-server-close! server)
(thread-wait accept-thread)
(for ([t (unbox served-threads)]) (thread-wait t))

(define failures
  (filter (lambda (cr) (not (eq? 'ok (unbox (cdr cr))))) client-results))
(unless (null? failures)
  (fail "racket-iroh-loop"
        (format "~a/~a client(s) failed; first: ~s"
                (length failures) NUM-CONNS (unbox (cdr (car failures))))))

;; Host teardown owns admission on every transport. A green thread parked on
;; iroh's reactor must wake terminally rather than retaining the endpoint.
(define closing (listen-iroh (make-iroh-config IROH-REACH-LOCAL-DISCOVERY)))
(define closing-result (make-channel))
(define closing-started (make-semaphore 0))
(define closing-accept
  (thread
   (lambda ()
     (semaphore-post closing-started)
     (channel-put closing-result
                  (with-handlers ([exn? values])
                    (iroh-server-accept closing)
                    'accepted)))))
(semaphore-wait closing-started)
(host-close! (iroh-server-host closing))
(define closing-terminal (sync/timeout 2 closing-result))
(unless (exn? closing-terminal)
  (fail "racket-iroh-loop" "Host release did not stop a parked iroh accept"))
(thread-wait closing-accept)
(iroh-server-close! closing)

(printf
 (string-append
  "racket-iroh-loop: OK, ~a concurrent iroh connections, ~a calls each, served "
  "from one loop over the readiness fd + non-blocking frame I/O\n")
 NUM-CONNS CALLS-PER-CONN)
