#lang racket/base
;; Internal: host action execute over the byte-fed host
;; (libpancake_driver, ADR-0072 / ADR-0079).
;;
;; Owns the shared C drain (`pancake_host_pump_drain`) with sync park-only
;; hooks, then honors each parked arm (`drain-host-actions!`). CapTP verbs stay
;; in `private/session.rkt`; far-vow handles live in `private/promise.rkt`; the
;; dial executor lives in `private/dial.rkt`; the host handle and vow table
;; stay in `private/host.rkt`.
;; Session and host require this module eagerly; this module lazy-requires
;; dial for `run-dial!` and session for close / settle helpers so the
;; session ↔ action and dial ↔ action cycles stay breakable (same pattern as
;; `pump.rkt`).

(require racket/lazy-require
         ffi/unsafe
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

(provide drain-host-actions!)

;; ── Park ──────────────────────────────────────────────────────────────────────
;; Run `pancake_host_pump_drain` with park-only arms; return decoded actions
;; in queue order. Views are copied inside `host-decode-action!` before the
;; next pop frees them. Caller holds the host lock; arms must not await.
(define (park-host-actions! m)
  (define parked '())
  (define (arm _ctx _host action out-progressed)
    (set! parked (cons (host-decode-action! action arg<-c) parked))
    (when out-progressed
      (ptr-set! out-progressed _uint32 1))
    OK)
  (define arm-cb (function-ptr arm _PancakeHostPumpArmFn))
  (define hooks (make-PancakeHostPumpHooks #f arm-cb arm-cb arm-cb arm-cb arm-cb))
  (check/host (pancake_host_pump_drain (host-ptr m) hooks #f))
  (reverse parked))

;; ── Execute ───────────────────────────────────────────────────────────────────
;; Honor one parked action under the host lock: FLUSH/NEED_GIFT_ID run here;
;; dial / close / settle / fail park as post-lock fires. Returns updated
;; `(values touched fires)`.
(define (apply-parked-action! m a touched fires)
  (case (car a)
    [(flush)
     (define c (host-session-for-ptr m (cadr a)))
     (cond
       [c
        (with-handlers ([converts-to-broken? void]) (drain-outbound! c))
        (values (if (memq c touched) touched (cons c touched)) fires)]
       [else (values touched fires)])]
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
        (values (if (memq c touched) touched (cons c touched))
                (cons (lambda () (session-close! c)) fires))]
       [else (values touched fires)])]
    [(dial)
     ;; A dial is a connect syscall plus a whole keyed handshake:
     ;; post-lock, like every write and fire, or one slow exporter
     ;; parks every thread sharing the host.
     (values touched (cons (lambda () (apply run-dial! m (cdr a))) fires))]
    [(need-gift-id)
     (host-provide-gift-id! m (cadr a))
     (values touched fires)]
    [(settle)
     (values touched (append (reverse (settle-vow! m (cadr a) (cons 'ok (caddr a)))) fires))]
    [(fail)
     (define outcome (cons (if (current-breaking) 'closed 'broken) (caddr a)))
     (values touched (append (reverse (settle-vow! m (cadr a) outcome)) fires))]
    [else (error 'pancake "unknown host action: ~a" a)]))

;; The one loop rule's drain: park via the shared C wrapper until dry, honoring
;; each arm, and return the `drain-effects` — parked writes and listener fires
;; — the caller runs with `run-drain-effects!` once the host lock is released.
;; The host lock is held. A NEED_GIFT_ID's provide may queue FLUSH legs, so we
;; re-park until the queue is empty (same as the pre-wrapper pull loop). FLUSH
;; order is action order, which is how the gifter's deposit leaves on the
;; exporter connection before the give leaves on the serving one (the host
;; queues them exporter-first); the per-connection FIFO preserves that order
;; across threads. SETTLE/FAIL route each vow's outcome to the `conn-vow`
;; awaiting that id — registered at mint under this same lock, so the
;; completion always finds its box.
(define (drain-host-actions! m)
  (let loop ([touched '()] [fires '()])
    (define parked (park-host-actions! m))
    (cond
      [(null? parked) (drain-effects (reverse touched) (reverse fires))]
      [else
       (define-values (t f)
         (for/fold ([touched touched] [fires fires]) ([a (in-list parked)])
           (apply-parked-action! m a touched fires)))
       (loop t f)])))
