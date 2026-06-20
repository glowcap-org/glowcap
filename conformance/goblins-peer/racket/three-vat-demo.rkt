#lang racket/base
;; three-vat-demo.rkt, proves Goblins/CapTP does real OCapN three-party
;; introduction (the "bash exec" property) over the TCP netlayer.
;;
;; Three real Vats, three TCP ports, three independent mycapn machine
;; routers. The flow:
;;
;;   1. Bob (port 9012) hosts a `^greeter` cap, registers it, hands the
;;      sturdyref to Alice out-of-band.
;;   2. Alice (port 9011) enlivens Bob's sturdyref. Alice now holds a
;;      LIVE remote-ref to Bob's greeter (this opens an Alice -> Bob
;;      TCP connection).
;;   3. Alice hosts an `^introducer` cap that, when invoked, returns
;;      the live ref to Bob's greeter.
;;   4. Carol (port 9013) enlivens Alice's introducer sturdyref
;;      (Carol -> Alice TCP connection opens).
;;   5. Carol invokes `(introducer 'get-greeter)` and gets back a vow
;;      that resolves to Bob's greeter.
;;   6. Carol invokes the greeter with her name. **The bytes go
;;      directly to Bob.** Each peer's netlayer has a trace callback;
;;      we record every TCP accept + connect. The load-bearing
;;      assertion: Bob's port saw a NEW inbound connection from Carol
;;      after the introduction. If Carol's traffic had been proxied
;;      through Alice, Bob would only ever see Alice's connection.
;;
;; This is the OCapN three-party-handoff test pancake will eventually
;; participate in. For now it validates that the Goblins reference
;; implementation actually does it.

(require goblins
         goblins/ocapn
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt"
         racket/async-channel
         racket/match)

;; ============================================================================
;; The capability Bob hosts
;; ============================================================================

(define (^greeter _bcom my-name)
  (lambda (your-name)
    (format "Hello ~a, I'm ~a, the bytes you just received came directly to me!"
            your-name my-name)))

;; ============================================================================
;; The introducer Alice hosts, holds a remote ref to Bob's greeter,
;; hands it out on request.
;; ============================================================================

(define (^introducer _bcom greeter-remote-ref)
  (lambda args
    (case (and (pair? args) (car args))
      [(get-greeter) greeter-remote-ref]
      [else (error '^introducer "unknown command: ~v" args)])))

;; ============================================================================
;; Per-peer trace tally, proves who dialed whom.
;; ============================================================================

(define alice-port 9011)
(define bob-port   9012)
(define carol-port 9013)

(define (make-trace-tally label)
  (define accepts (box 0))
  (define connects (box '()))
  (values
   accepts
   connects
   (lambda (event . args)
     (case event
       [(accept)
        (set-box! accepts (add1 (unbox accepts)))
        (printf "  [trace ~a] ACCEPT (incoming TCP conn) #~a~n"
                label (unbox accepts))]
       [(connect)
        (define remote (cadr args))
        (define remote-designator (ocapn-node-designator remote))
        (set-box! connects (cons remote-designator (unbox connects)))
        (printf "  [trace ~a] CONNECT (outbound) -> ~a~n"
                label remote-designator)]))))

(define-values (alice-accepts alice-connects alice-trace)
  (make-trace-tally "Alice"))
(define-values (bob-accepts bob-connects bob-trace)
  (make-trace-tally "Bob"))
(define-values (carol-accepts carol-connects carol-trace)
  (make-trace-tally "Carol"))

;; ============================================================================
;; Bob, bind, host greeter, hand sturdyref to Alice
;; ============================================================================

(printf "~n=== Bob: binding 127.0.0.1:~a, hosting greeter ===~n" bob-port)

(define-vat-run bob-machine-run (make-vat))
(define bob-netlayer
  (bob-machine-run
   (spawn ^tcp-netlayer "127.0.0.1" bob-port #:trace bob-trace)))
(define bob-mycapn
  (bob-machine-run (spawn-mycapn bob-netlayer)))

(define-vat-run bob-vat-run (make-vat))
(define bob-greeter
  (bob-vat-run (spawn ^greeter "Bob")))
(define bob-greeter-sref
  (bob-machine-run ($ bob-mycapn 'register bob-greeter 'tcp)))

;; ============================================================================
;; Alice, bind, enliven Bob's greeter, host introducer
;; ============================================================================

(printf "~n=== Alice: binding 127.0.0.1:~a, enlivening Bob's greeter ===~n" alice-port)

(define-vat-run alice-machine-run (make-vat))
(define alice-netlayer
  (alice-machine-run
   (spawn ^tcp-netlayer "127.0.0.1" alice-port #:trace alice-trace)))
(define alice-mycapn
  (alice-machine-run (spawn-mycapn alice-netlayer)))

;; Alice opens an Alice -> Bob TCP connection here (enliven dials Bob).
(define-vat-run alice-vat-run (make-vat))
(define alice-greeter-ref-vow
  (alice-machine-run (<- alice-mycapn 'enliven bob-greeter-sref)))

;; Wait briefly for the Alice -> Bob connection so the trace is
;; deterministic before Carol enters.
(sleep 0.3)

;; Spawn the introducer in Alice's vat with the greeter live-ref vow.
;; (Goblins promise pipelining means we can pass the vow as if it were
;; the resolved ref; the introducer's `get-greeter` returns the vow,
;; which Carol will get and pipeline against.)
(define alice-introducer
  (alice-vat-run
   (spawn ^introducer alice-greeter-ref-vow)))
(define alice-introducer-sref
  (alice-machine-run
   ($ alice-mycapn 'register alice-introducer 'tcp)))

;; ============================================================================
;; Carol, bind, dial Alice, ask for the greeter, invoke it
;; ============================================================================

(printf "~n=== Carol: binding 127.0.0.1:~a, will enliven Alice's introducer ===~n" carol-port)

(define-vat-run carol-machine-run (make-vat))
(define carol-netlayer
  (carol-machine-run
   (spawn ^tcp-netlayer "127.0.0.1" carol-port #:trace carol-trace)))
(define carol-mycapn
  (carol-machine-run (spawn-mycapn carol-netlayer)))

(define-vat-run carol-vat-run (make-vat))

(define response-ch (make-async-channel))

(carol-vat-run
 (printf "~n  [Carol] enlivening Alice's introducer sturdyref...~n")
 (define introducer-vow
   (<- carol-mycapn 'enliven alice-introducer-sref))
 (printf "  [Carol] asking introducer for the greeter (this is the introduction)...~n")
 (define greeter-vow (<- introducer-vow 'get-greeter))
  (printf "  [Carol] invoking the greeter; bytes should go directly to Bob...~n")
 (on (<- greeter-vow "Carol")
     (lambda (val)
       (async-channel-put response-ch `(ok ,val)))
     #:catch
     (lambda (err)
       (async-channel-put response-ch `(err ,err)))))

(define reply (sync/timeout 10.0 response-ch))

;; Give a moment for any post-reply trace events to settle.
(sleep 0.3)

;; ============================================================================
;; Verdict
;; ============================================================================

(printf "~n========================================================================~n")
(printf "  THREE-VAT INTRODUCTION VERDICT~n")
(printf "========================================================================~n")

(case (and (pair? reply) (car reply))
  [(ok)
   (printf "~n  Carol's greeter call succeeded. Reply: ~a~n" (cadr reply))]
  [(err)
   (printf "~n  Carol's greeter call FAILED, broken promise: ~v~n" (cadr reply))
   (exit 1)]
  [else
   (printf "~n  Carol's greeter call TIMED OUT (no reply within 10s)~n")
   (exit 1)])

(printf "~n  Trace summary:~n")
(printf "    Alice  accepts=~a  connects-to=~v~n"
        (unbox alice-accepts) (reverse (unbox alice-connects)))
(printf "    Bob    accepts=~a  connects-to=~v~n"
        (unbox bob-accepts)   (reverse (unbox bob-connects)))
(printf "    Carol  accepts=~a  connects-to=~v~n"
        (unbox carol-accepts) (reverse (unbox carol-connects)))

;; Load-bearing assertion: Bob accepted at least 2 inbound connections.
;;   1. Alice -> Bob (when Alice enlivened Bob's greeter)
;;   2. Carol -> Bob (when introduction handed Bob's ref to Carol and
;;      Carol's mycapn dialed Bob directly)
;;
;; If Goblins had only Cap'n-Proto-RPC-level-2 semantics (no
;; introduction), Carol would never dial Bob, her traffic would proxy
;; through Alice. In that world, Bob.accepts would stay at 1.
(printf "~n  Assertion: Bob's accepts >= 2 (introduction worked, Carol dialed Bob directly)~n")
(define introduction-worked? (>= (unbox bob-accepts) 2))
(printf "    -> ~a~n" (if introduction-worked? "PASS" "FAIL"))

(unless introduction-worked?
  (printf "~n  WHY IT MATTERS: A failure here means Carol's bytes routed THROUGH~n")
  (printf "  Alice (proxying), not direct to Bob. That's what level-2 RPC does;~n")
  (printf "  three-party introduction (CapTP level 3) is what makes it the~n")
  (printf "  'OCapN exec', the introducer steps OUT of the data path.~n")
  (exit 1))

;; Bonus assertion: Carol has dialed BOTH Alice and Bob (proves the
;; introduction triggered a fresh outbound from Carol).
(define carol-dialed-both?
  (and (member (format "127.0.0.1:~a" alice-port) (unbox carol-connects))
       (member (format "127.0.0.1:~a" bob-port)   (unbox carol-connects))))
(printf "~n  Assertion: Carol dialed both Alice and Bob~n")
(printf "    -> ~a~n" (if carol-dialed-both? "PASS" "FAIL"))

(unless carol-dialed-both?
  (exit 1))

(printf "~n  Three-vat OCapN-style introduction works on Goblins/CapTP/TCP.~n")
(printf "  (CapTP spec calls this 'three-party handoff'; Cap'n Proto's~n")
(printf "   spec covers it at level 3, but capnp-rpc-rust is typically~n")
(printf "   level 2 in practice.)~n~n")
(exit 0)
