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

(define server (listen-iroh IROH-REACH-LOCAL-DISCOVERY))
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
         (define conn (iroh-server-accept server))
         (session-publish conn "greeter" greeter)
         (set-box! served-threads
                   (cons (thread (lambda () (session-serve conn))) (unbox served-threads)))
         (loop))))))

;; One client: bind its own iroh endpoint, dial the server by id alone (the
;; local-discovery book resolves it), fetch the greeter, and call it
;; CALLS-PER-CONN times, checking every reply.
(define (client-once)
  (define conn (connect (format-peer-uri TRANSPORT-IROH server-id) IROH-REACH-LOCAL-DISCOVERY))
  (dynamic-wind
   void
   (lambda ()
     (define greeter-cap (session-fetch conn "greeter"))
     (for ([_ (in-range CALLS-PER-CONN)])
       (define reply (session-send conn greeter-cap 'greet "world"))
       (unless (equal? reply GREETING)
         (error 'client (format "wrong reply: ~s" reply)))))
   (lambda () (session-close! conn))))

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

;; Bring the server down so the accept thread ends and no readiness thread
;; outlives the endpoint it watches.
(iroh-server-close! server)
(thread-wait accept-thread)
(for ([t (unbox served-threads)]) (thread-wait t))

(define failures
  (filter (lambda (cr) (not (eq? 'ok (unbox (cdr cr))))) client-results))
(unless (null? failures)
  (fail (format "~a/~a client(s) failed; first: ~s"
                (length failures) NUM-CONNS (unbox (cdr (car failures))))))

(printf
 (string-append
  "racket-iroh-loop: OK, ~a concurrent iroh connections, ~a calls each, served "
  "from one loop over the readiness fd + non-blocking frame I/O\n")
 NUM-CONNS CALLS-PER-CONN)
