#lang racket/base
;; captp-demo.rkt: two Goblins peers chatting over real CapTP, in-process.
;;
;; Demonstrates that this Vat is CapTP-capable. Two independent Goblins
;; "machines" (each with its own vat, netlayer, and `mycapn` router) run
;; in this single Racket process and exchange a real OCapN
;; capability-invocation message through Spritely's CapTP, using the
;; `fake-intarwebs` netlayer (in-process, but real CapTP semantics).
;;
;; This is the Goblins-only, in-process control: it pins CapTP semantics above
;; a fake netlayer without making a claim about glowcap. `tcp-demo.rkt` holds
;; the corresponding real-socket control; `goblins-interop` and the live
;; handoff/gift/exporter rows cover the cross-implementation seams.
;;
;; What this does NOT yet do:
;;   - Speak to a non-Goblins peer (the netlayer is in-process).
;;   - Hook into the kernel loop's KERI / Episode / transparency-log
;;     machinery: this is a CapTP-shape demo, not a kernel demo.
;;   - Authenticate / authorize beyond CapTP's own session keys.

(require goblins
         goblins/ocapn
         goblins/ocapn/netlayer/fake-intarwebs
         goblins/ocapn/structs-urls
         racket/async-channel)

;; ============================================================================
;; The cap we'll expose: a trivial greeter that echoes back a name.
;; ============================================================================
;; This is the "Affordance" the kernel loop also uses, just without
;; the Episode / signing / transparency-log machinery.

(define (^greeter _bcom my-name)
  (lambda (your-name)
    (format "Hello ~a, this is ~a (over CapTP)!" your-name my-name)))

;; ============================================================================
;; Set up the fake-intarwebs network, both peers route through it.
;; ============================================================================
;; In a real netlayer (Tor, TCP, etc.) the `network` actor is replaced by
;; the actual transport. The CapTP machinery above the netlayer is unchanged.

(define-vat-run network-vat-run (make-vat))
(define network (network-vat-run (spawn ^fake-network)))

;; Each peer has:
;;   - its own vat (event loop)
;;   - its own async-channel for incoming connections (the netlayer's "inbox")
;;   - a fake-netlayer connected to the shared `network`
;;   - a `mycapn` machine router

(define-vat-run a-run (make-vat))
(define-vat-run b-run (make-vat))

(define a-incoming (make-async-channel))
(define b-incoming (make-async-channel))

(define a-fake-netlayer
  (a-run (spawn ^fake-netlayer "a" network a-incoming)))
(define b-fake-netlayer
  (b-run (spawn ^fake-netlayer "b" network b-incoming)))

(network-vat-run
 ($ network 'register "a" a-incoming)
 ($ network 'register "b" b-incoming))

(define a-location (string->ocapn-node "ocapn://a.fake"))
(define b-location (string->ocapn-node "ocapn://b.fake"))

(define a-mycapn (a-run (spawn-mycapn a-fake-netlayer)))
(define b-mycapn (b-run (spawn-mycapn b-fake-netlayer)))

;; Wire up the connections explicitly (in some netlayers `enliven`
;; auto-connects; doing it here makes the demo trace easier to read).
;; The promise returned by `connect-to-node` is for sequencing only; we
;; don't need its value, so void it to keep stdout clean.
(void (a-run ($ a-mycapn 'connect-to-node b-location)))
(void (b-run ($ b-mycapn 'connect-to-node a-location)))

;; ============================================================================
;; Side A spawns a greeter, registers it with mycapn, gets a sturdyref.
;; ============================================================================

(define alice (a-run (spawn ^greeter "Alice (Goblins peer A)")))
(define alice-sturdyref
  (a-run ($ a-mycapn 'register alice 'fake)))

(printf "[demo] Side-A registered greeter; sturdyref: ~v~n" alice-sturdyref)

;; ============================================================================
;; Side B enlivens the sturdyref and sends a real CapTP message.
;; ============================================================================
;; The message goes through:
;;   B's vat -> B's mycapn -> B's netlayer (encodes Syrup) ->
;;   shared fake-network (in real life: the wire) ->
;;   A's netlayer (decodes Syrup) -> A's mycapn -> A's vat -> alice
;; And the reply traverses the same path in reverse.

(define response-ch (make-async-channel))

(b-run
 (printf "[demo] Side-B enlivening sturdyref...~n")
 (define alice-vow (<- b-mycapn 'enliven alice-sturdyref))
 (printf "[demo] Side-B sending greeting via real CapTP...~n")
 (on (<- alice-vow "Bob (Goblins peer B)")
     (lambda (val)
       (async-channel-put response-ch `(ok ,val)))
     #:catch
     (lambda (err)
       (async-channel-put response-ch `(err ,err)))))

;; Wait for the reply (or timeout). 0.5s is generous for in-process CapTP;
;; over a real netlayer this is round-trip latency.
(define reply (sync/timeout 2.0 response-ch))

(case (and (pair? reply) (car reply))
  [(ok)
   (printf "~n[demo] OK — full CapTP roundtrip~n")
   (printf "       Side-B heard back: ~a~n" (cadr reply))
   (printf "       The bytes that flowed used Spritely's Syrup wire format,~n")
   (printf "       routed through `fake-intarwebs` (in-process), but the~n")
   (printf "       CapTP machinery on top is the same machinery a real~n")
   (printf "       Tor / TCP / Iroh netlayer would carry.~n")]
  [(err)
   (printf "~n[demo] FAILED — broken promise: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "~n[demo] FAILED — timeout (no reply within 2s)~n")
   (exit 1)])
