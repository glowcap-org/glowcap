#lang racket/base
;; Internal: host action execute over the byte-fed host
;; (libpancake_driver, ADR-0072 / ADR-0079).
;;
;; Owns popping one embedder effect from `pancake_host_next_action`
;; (`host-next-action!`, decode via generated `host-decode-action!`) and the
;; drain switch that honors each arm (`drain-host-actions!`). CapTP verbs stay
;; in `private/session.rkt`; far-vow handles live in `private/promise.rkt`; the
;; dial executor lives in `private/dial.rkt`; the host handle and vow table
;; stay in `private/host.rkt`.
;; Session and host require this module eagerly; this module lazy-requires
;; dial for `run-dial!` and session for close / settle helpers so the
;; session ↔ action and dial ↔ action cycles stay breakable (same pattern as
;; `pump.rkt`).

(require racket/lazy-require
         "constants.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
         "codec.rkt"
         "vat.rkt"
         "host.rkt"
         "pump.rkt"
         "host-action-gen.rkt")

;; Dial owns run-dial!; session owns session-close! and the breaking
;; parameter the FAIL arm consults. Promise owns settle-vow!. Lazy-require
;; breaks the dial/session ↔ action and promise ↔ session cycles.
(lazy-require
 ["promise.rkt"
  (settle-vow!)]
 ["dial.rkt"
  (run-dial!)]
 ["session.rkt"
  (session-close!
   current-breaking)])

(provide host-next-action!
         drain-host-actions!)

;; ── Decode ────────────────────────────────────────────────────────────────────
;; Pop the next embedder action, its borrowed views copied into Racket values
;; before anything else can call `pancake_host_next_action` (which frees them):
;; `(list 'dial ticket transport designator direct-addresses-hint)`,
;; `(list 'flush conn-ptr)`, `(list 'close conn-ptr)` (write the condemned
;; session's queued abort, then close and release it),
;; `(list 'need-gift-id ticket)`,
;; `(list 'settle vow-id value)` / `(list 'fail vow-id message)` — a host
;; vow's outcome, routed by the drain to the `session-vow` awaiting that id — or
;; #f when the queue is dry. Caller holds the host lock.
(define (host-next-action! m)
  (define a (host-action-scratch m))
  (define rc (pancake_host_next_action (host-ptr m) a))
  (cond
    [(= rc WOULD-BLOCK) #f]
    [else
     (check/host rc)
     (host-decode-action! a arg<-c)]))

;; ── Execute ───────────────────────────────────────────────────────────────────
;; The one loop rule's drain: pop actions until dry, honoring each, and return
;; the `drain-effects` — parked writes and listener fires — the caller runs
;; with `run-drain-effects!` once the host lock is released. The host lock is
;; held. FLUSH order is action order, which is how the gifter's deposit leaves
;; on the exporter connection before the give leaves on the serving one (the
;; host queues them exporter-first); the per-connection FIFO preserves that
;; order across threads. SETTLE/FAIL route each vow's outcome to the
;; `conn-vow` awaiting that id — registered at mint under this same lock, so
;; the completion always finds its box.
(define (drain-host-actions! m)
  (let loop ([touched '()] [fires '()])
    (define a (host-next-action! m))
    (cond
      [(not a) (drain-effects (reverse touched) (reverse fires))]
      [else
       (case (car a)
         [(flush)
          (define c (host-session-for-ptr m (cadr a)))
          (cond
            [c
             (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
             (loop (if (memq c touched) touched (cons c touched)) fires)]
            [else (loop touched fires)])]
         [(close)
          ;; The host condemned the connection mid-pump (local turn budget
          ;; exceeded): drain its queued resource_exhausted abort so the
          ;; post-lock write carries it, then close the transport and release
          ;; the shell — deferred to the fires, which run after the touched
          ;; writes, once the host lock is released.
          (define c (host-session-for-ptr m (cadr a)))
          (cond
            [c
             (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
             (loop (if (memq c touched) touched (cons c touched))
                   (cons (lambda () (session-close! c)) fires))]
            [else (loop touched fires)])]
         [(dial)
          ;; A dial is a connect syscall plus a whole keyed handshake:
          ;; post-lock, like every write and fire, or one slow exporter
          ;; parks every thread sharing the host.
          (loop touched (cons (lambda () (apply run-dial! m (cdr a))) fires))]
         [(need-gift-id) (host-provide-gift-id! m (cadr a)) (loop touched fires)]
         [(settle)
          (loop touched (append (reverse (settle-vow! m (cadr a) (cons 'ok (caddr a)))) fires))]
         [(fail)
          (define outcome (cons (if (current-breaking) 'closed 'broken) (caddr a)))
          (loop touched (append (reverse (settle-vow! m (cadr a) outcome)) fires))]
         [else (error 'pancake "unknown host action: ~a" a)])])))
