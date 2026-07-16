#lang racket/base
;; pancake backend with time-travel ON for every actor — the third bench series.
;; It is `backend-pancake` in every respect but one: each accepted connection's
;; server vat retains a revisable behavior history (`accept #:time-travel? #t`),
;; so the comparison isolates a single variable — the cost of leaving pancake's
;; snapshot feature on for all actors, the way Goblins always runs it. The client
;; path is unchanged, since time-travel is a local property of the vat that hosts
;; the actors, so the client procs are reused verbatim from `backend-pancake`.
(require (file "/workspaces/pancake/bindings/racket/pancake.rkt")
         (only-in (file "/workspaces/pancake/bench/goblins/backend-pancake.rkt")
                  client-connect client-fetch client-call client-close))

(provide server-run client-connect client-fetch client-call client-close)

;; Serve forever like `backend-pancake`, but accept each connection with
;; time-travel enabled so every actor the app spawns is snapshottable/revisable.
(define (server-run name host port build-root)
  (define srv (listen host port))
  (printf "{\"v\":1,\"event\":\"ready\",\"listen\":\"~a:~a\"}\n" host (server-port srv))
  (flush-output)
  (let accept-loop ()
    (define hconn (accept srv #:time-travel? #t))
    (thread
     (lambda ()
       (define (mint-cap ctor) (session-spawn hconn ctor))
       (session-publish hconn name (build-root mint-cap))
       (session-serve hconn)))
    (accept-loop)))
