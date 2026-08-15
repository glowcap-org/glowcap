#lang racket/base
;; pancake backend for the bench suite. Wraps the Racket binding's high-level TCP
;; lifecycle behind the suite's substrate-blind API. The binding's `session-send` and
;; `session-fetch` already are the run-to-quiescence driver — they issue an
;; eventual-send and pump the sans-io peer until the reply settles — so they are
;; the fair, idiomatic pancake analog of Goblins' vat loop. No application logic
;; lives here.
(require (file "/workspaces/pancake/bindings/racket/pancake.rkt")
         (file "/workspaces/pancake/bindings/racket/pancake-tcp.rkt"))

(provide server-run client-connect client-fetch client-call client-close)

;; Serve forever: accept each connection, publish the app root (built with a
;; connection-scoped mint-cap that exports + publishes any capability a handler
;; returns), and serve it on its own thread. build-root : mint-cap -> root-ctor.
;; Do not swallow serve faults — `session-serve` closes the transport on error;
;; a swallowed exception left partners hung on a half-open TCP.
(define (server-run name host port build-root)
  (define srv (listen host port))
  (printf "{\"v\":1,\"event\":\"ready\",\"listen\":\"~a:~a\"}\n" host (server-port srv))
  (flush-output)
  (let accept-loop ()
    (define hconn (accept srv))
    (thread
     (lambda ()
       (define (mint-cap ctor) (session-spawn hconn ctor))
       (session-publish hconn name (build-root mint-cap))
       (session-serve hconn)))
    (accept-loop)))

(struct pclient (runtime conn))

(define (client-connect host port)
  (define runtime (open-runtime #:providers (list (tcp-provider))))
  (pclient runtime (runtime-connect runtime (tcp-locator host port))))

(define (client-fetch handle name) (session-fetch (pclient-conn handle) name))

;; Synchronous send + settle, returning the fulfilled value (raises on a break).
(define (client-call handle ref method . args)
  (apply session-send (pclient-conn handle) ref method args))

(define (client-close handle)
  (session-close! (pclient-conn handle))
  (runtime-close! (pclient-runtime handle)))
