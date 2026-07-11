#lang racket/base
;; Internal: the CapTP node — pancake's analogue of Goblins' `mycapn`, one per
;; node — over the byte-fed host archive (libpancake_driver, ADR-0072). The
;; `PancakeHost` owns every decision: the retained identity, the shared gift
;; registry, routing, transparent three-party redemption, and the gifter half's
;; origination. What lives here is only what the embedder contract leaves to
;; the binding: the host handle and its reentrant lock (one green-thread
;; scheduler drives one host, and the lock is what makes "one at a time" true
;; across this binding's threads), the conn-pointer → connection registry the
;; action drain routes by, the giftable trampolines' strong retention, gift-id
;; entropy, and the iroh redeem-reachability posture the dial executor reads.
;; The pump and the dial executor themselves live in `private/connection.rkt`,
;; which owns the `connection` type they act on.

(require ffi/unsafe
         racket/random
         "constants.rkt"
         "ffi-shared.rkt"
         "ffi-driver.rkt"
         "errors.rkt"
         "codec.rkt"
         "trampoline.rkt")

(provide (all-defined-out))

;; Every connection's maximum admissible frame, mirroring the engine's default
;; session limit; the core's stream delimiter (`pancake_host_conn_feed_bytes`)
;; enforces it while it scans, so a hostile stream cannot grow the inbox past
;; it.
(define HOST-FRAME-CAP (expt 2 20))

;; The node. `ptr` is the PancakeHost handle; `lock`/`lock-owner` form the
;; reentrant host lock every `pancake_host_*` verb and action drain runs under;
;; `conns` maps a conn pointer's address to its live `connection` (the FLUSH
;; action's routing table, and what keeps redeem-dialed exporter connections
;; alive); `progress` boxes the generation semaphore pumps wait on — bumped
;; after every locked host operation, so a thread parked on one connection
;; notices a settle another connection's feed fired; `keep` strongly retains
;; every behavior closure registered with the host (a C trampoline stays alive
;; only while its Racket closure does); `vows` maps a host vow id to the
;; `conn-vow` awaiting it, filled at mint under the node lock and settled by
;; the drain's SETTLE/FAIL arms (`private/connection.rkt`), so no callback
;; ever crosses the C boundary for a settlement; `redeem-reachability` is the
;; iroh posture a hint-less handoff give is redeemed under (default Discovery,
;; 1; `set-node-redeem-reachability!` lowers it for a relay-policy
;; deployment); `released?` guards the handle against use after release;
;; `action-scratch` is the one cstruct `node-next-action!` pops into, reused
;; across pops — every pop runs under the node lock and copies its borrowed
;; views out before the next pop overwrites it.
(struct node (ptr lock lock-owner conns progress keep vows redeem-reachability released? codec action-scratch))

;; `#:codec` is the wire grammar every connection this node mints negotiates
;; in ('syrup by default, 'capnp for a Cap'n Proto session); both ends of a
;; connection must carry the same codec. The node remembers the symbol so
;; `connect` can refuse an explicit codec that conflicts with a shared node's.
(define (make-node seed #:codec [codec 'syrup])
  (define sbuf (pin-immobile seed)) ; pin: the GC may move `seed` mid-call
  (define-values (rc ptr) (pancake_host_new sbuf 32 HOST-FRAME-CAP 1 (codec-id codec)))
  (check/host rc)
  (define m (node ptr (make-semaphore 1) (box #f) (make-hash) (box (make-semaphore 0))
                  (make-hasheq) (make-hash) (box 1) (box #f) codec
                  (make-PancakeHostAction 0 0 #f #f 0 #f 0 #f 0 #f 0
                                          (make-PancakeArgument 0 0 0 0.0 #f 0 (make-PancakeReference 0 0 0) #f 0)
                                          #f 0)))
  (register-finalizer m (lambda (q) (node-release! q)))
  m)

;; A node with a fresh random identity seed — entropy drawn at the binding
;; boundary, never inside the sans-io host.
(define (make-fresh-node #:codec [codec 'syrup]) (make-node (crypto-random-bytes 32) #:codec codec))

;; Release the host and everything it owns. The finalizer fallback for a
;; dropped node; connections this node minted die with it, so it runs only
;; once nothing else can reach them.
(define (node-release! m)
  (unless (unbox (node-released? m))
    (set-box! (node-released? m) #t)
    (pancake_host_release (node-ptr m))))

;; ── The reentrant host lock ───────────────────────────────────────────────────
;; One thread (or one green-thread scheduler) drives one host; nothing in the C
;; tier locks. Racket green threads preempt between expressions, so this lock is
;; what serializes a whole verb-plus-drain sequence against the other threads
;; sharing the node (a server's accepted connections, a gifter's exporter
;; dial). Reentrant by owner thread: a behavior fired inside a locked feed
;; drain calls enqueueing host verbs of its own (a hosted turn's `conn-tell`
;; or spawn), and those inner entries must not self-deadlock.
(define (call-with-node m thunk)
  (define owner (node-lock-owner m))
  (cond
    [(eq? (unbox owner) (current-thread)) (thunk)]
    [else
     (call-with-semaphore
      (node-lock m)
      (lambda ()
        (set-box! owner (current-thread))
        (dynamic-wind void thunk (lambda () (set-box! owner #f)))))]))

;; ── Progress: how a parked pump notices another thread's work ─────────────────
;; `node-progress-evt` is an event that fires when any host progress has been
;; made since it was read; a pump snapshots it, re-checks its predicate, then
;; waits on the snapshot together with its own transport. `semaphore-peek-evt`
;; wakes every waiter without consuming the post.
(define (node-progress-evt m) (semaphore-peek-evt (unbox (node-progress m))))

(define (node-bump-progress! m)
  (define old (unbox (node-progress m)))
  (set-box! (node-progress m) (make-semaphore 0))
  (semaphore-post old))

;; ── Callback retention ────────────────────────────────────────────────────────
;; Strongly retain `cb` (a behavior closure whose C trampoline the host
;; holds) until `node-retire!` drops it — in practice never: a behavior lives
;; as long as its host. Settlements retain nothing; they ride the action
;; queue.
(define (node-retain! m cb) (hash-set! (node-keep m) cb #t))
(define (node-retire! m cb) (hash-remove! (node-keep m) cb))

;; ── Connection registry ───────────────────────────────────────────────────────
(define (conn-key ptr) (cast ptr _pointer _uintptr))
(define (node-register-connection! m ptr c) (hash-set! (node-conns m) (conn-key ptr) c))
(define (node-unregister-connection! m ptr) (hash-remove! (node-conns m) (conn-key ptr)))
(define (node-connection-for-ptr m ptr) (hash-ref (node-conns m) (conn-key ptr) #f))

;; ── Host verbs the drain loop answers actions with ───────────────────────────
;; Pop the next embedder action, its borrowed views copied into Racket values
;; before anything else can call `pancake_host_next_action` (which frees them):
;; `(list 'dial ticket locator-uri transport designator direct-addresses)` —
;; the locator's parsed pieces ride the action, so the dial executor never
;; re-parses the URI — `(list 'flush conn-ptr)`, `(list 'close conn-ptr)`
;; (write the condemned connection's queued abort, then close and release it),
;; `(list 'need-gift-id ticket)`,
;; `(list 'settle vow-id value)` / `(list 'fail vow-id message)` — a host
;; vow's outcome, routed by the drain to the `conn-vow` awaiting that id — or
;; #f when the queue is dry. Caller holds the node lock.
(define (node-next-action! m)
  (define a (node-action-scratch m))
  (define rc (pancake_host_next_action (node-ptr m) a))
  (cond
    [(= rc WOULD-BLOCK) #f]
    [else
     (check/host rc)
     (define kind (PancakeHostAction-kind a))
     (define (view->string ptr len) (bytes->string/utf-8 (bytes<-c ptr len) #\uFFFD))
     (cond
       [(= kind HOST-ACTION-DIAL)
        (list 'dial (PancakeHostAction-ticket a)
              (view->string (PancakeHostAction-locator a) (PancakeHostAction-locator-len a))
              (view->string (PancakeHostAction-transport a) (PancakeHostAction-transport-len a))
              (view->string (PancakeHostAction-designator a) (PancakeHostAction-designator-len a))
              (view->string (PancakeHostAction-direct-addresses-hint a)
                            (PancakeHostAction-direct-addresses-hint-len a)))]
       [(= kind HOST-ACTION-FLUSH) (list 'flush (PancakeHostAction-conn a))]
       [(= kind HOST-ACTION-CLOSE) (list 'close (PancakeHostAction-conn a))]
       [(= kind HOST-ACTION-NEED-GIFT-ID) (list 'need-gift-id (PancakeHostAction-ticket a))]
       ;; `arg<-c` copies every byte payload into fresh Racket values, so the
       ;; outcome outlives the popped action's until-next-pop lifetime.
       [(= kind HOST-ACTION-SETTLE)
        (list 'settle (PancakeHostAction-ticket a) (arg<-c (PancakeHostAction-value a)))]
       [(= kind HOST-ACTION-FAIL)
        (list 'fail (PancakeHostAction-ticket a)
              (view->string (PancakeHostAction-message a) (PancakeHostAction-message-len a)))]
       [else (error 'pancake "unknown host action kind: ~a" kind)])]))

;; Answer a NEED_GIFT_ID action: entropy is a host effect, drawn only when a
;; reply actually becomes a gift. The host originates the claimed handoff and
;; flushes its legs, exporter first. Caller holds the node lock.
(define (node-provide-gift-id! m ticket)
  (define id (crypto-random-bytes 32))
  (check/host (pancake_host_provide_gift_id (node-ptr m) ticket (pin-immobile id) 32)))

;; Report a DIAL action's outcome. Caller holds the node lock.
(define (node-dialed! m ticket conn-ptr)
  (check/host (pancake_host_dialed (node-ptr m) ticket conn-ptr)))

(define (node-dial-failed! m ticket reason)
  (define bs (string->bytes/utf-8 reason))
  (check/host (pancake_host_dial_failed (node-ptr m) ticket (pin-immobile bs) (bytes-length bs))))

;; Record the designator this node's dials sign as their own dialable address
;; (a node that also listens); `listen` / `listen-iroh` set it to the bound
;; address so a partner's crossed-hellos table can recognize this node.
(define (node-set-self-designator! m designator)
  (define bs (string->bytes/utf-8 designator))
  (call-with-node m
    (lambda ()
      (check/host (pancake_host_set_self_designator (node-ptr m) (pin-immobile bs) (bytes-length bs))))))

;; ── Node-wide giftables ───────────────────────────────────────────────────────
;; Publish `behavior` under `name` on every connection of this node — those open
;; now and any accepted later — so a recipient can withdraw a gift naming it on a
;; connection it dialed itself (the exporter half of a three-party handoff). The
;; replay onto future connections is host-internal (`pancake_host_publish`); the
;; binding keeps only the trampoline alive. The behavior is an ordinary actor
;; behavior `(lambda (method . args) …)`, e.g. one built with `methods`.
(define (node-publish-giftable m name behavior)
  (define tramp (make-giftable-trampoline behavior))
  (node-retain! m tramp)
  (define nb (string->bytes/utf-8 name))
  (call-with-node m
    (lambda ()
      (check/host (pancake_host_publish (node-ptr m) (pin-immobile nb) (bytes-length nb)
                                        tramp #f #f)))))

;; ── The hint-less iroh redeem posture ─────────────────────────────────────────
;; The iroh reachability posture this node uses to redeem a hint-less handoff
;; give — one whose exporter location names the exporter by node id alone, so
;; the recipient must resolve it by id. Defaults to Discovery (1), the
;; maximal-reach choice; a relay-policy node lowers it to DiscoveryNoRelay. A
;; hinted give always dials Direct and ignores it. Stored as the numeric value
;; so the core stays free of the iroh companion.
(define (node-redeem-reachability-value m) (unbox (node-redeem-reachability m)))
(define (set-node-redeem-reachability! m reachability)
  (set-box! (node-redeem-reachability m) reachability))
