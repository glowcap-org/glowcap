#lang racket/base
;; Live three-party handoff with the Racket binding as the GIFTER (the
;; introducer), proving pancake can mint a `desc:handoff-give` that live Goblins
;; redeems and a `deposit-gift` that live Goblins accepts, the exporter half of
;; ADR-0009 against a real cross-implementation peer, the mirror of
;; `racket-goblins-handoff` (where pancake is the recipient).
;;
;; Topology (all TCP loopback):
;;   Bob    (Goblins exporter)  hosts a greeter behind a swiss; long-lived.
;;   Gifter (pancake)           fetches Bob's greeter, publishes an "introducer"
;;                              that returns it, and listens for the recipient.
;;   Carol  (Goblins recipient) dials the pancake introducer, asks for the
;;                              greeter, transparently redeems pancake's give, and
;;                              calls the greeter directly on Bob.
;;
;; pancake is the gifter: when Carol asks for the greeter, pancake deposits it
;; back with Bob over its own Bob connection and resolves Carol's send with a
;; signed give. Goblins Bob must accept pancake's deposit; Goblins Carol must
;; redeem pancake's give and reach Bob directly. The proof is Carol's `GIFT OK`
;; line carrying the greeter's reply with the name she sent.
;;
;; Needs `racket` plus the `goblins` collection on PATH; run via
;; `zig build racket-goblins-gift`.

(require "../../bindings/racket/pancake.rkt"
         racket/port
         racket/string
         "../_common/racket/helpers.rkt")

(define HOST "127.0.0.1")
;; Bob (the Goblins exporter) listens on PORT; Carol binds her own peer on PORT+1.
;; pancake (the gifter) takes an ephemeral port, the recipient learns it at spawn
;; time. --port=N (from `zig build racket-goblins-gift -Dport=N`) moves the pair.
(define PORT (parse-port "racket-goblins-gift" 22126 65534))
(define RACKET
  (or (find-executable-path "racket")
      (error 'racket-gift-client "racket executable not found on PATH")))
(define EXPORTER-SCRIPT "conformance/goblins-peer/racket/gift-exporter-host.rkt")
(define RECIPIENT-SCRIPT "conformance/goblins-peer/racket/gift-recipient.rkt")
;; pancake hardcodes the same swiss the exporter host registers, the way the
;; interop clients fix the echo swiss.
(define GREETER-SWISS "pancakeGiftGreeterSwissnum000001")
(define INTRODUCER-SWISS "introducer")

;; Track spawned Goblins peers so any failure tears them down: a lingering
;; listener on a fixed port poisons later runs.
(define children (box '()))
(define (track-child! p) (set-box! children (cons p (unbox children))))
(define (kill-children!)
  (for ([p (in-list (unbox children))])
    (with-handlers ([(lambda (_) #t) void]) (subprocess-kill p #t))))

;; Spawn Bob (the Goblins exporter) and drain its stderr in the background. A
;; piped child stream that is never read deadlocks the child once its OS pipe
;; fills, Goblins logs to stderr during operation, so leaving it undrained
;; stalls the deposit and the whole handoff times out. The captured text is
;; printed only on failure.
(define-values (bob bob-out bob-in bob-err)
  (subprocess #f #f #f RACKET EXPORTER-SCRIPT HOST (number->string PORT)))
(track-child! bob)
(close-output-port bob-in)
(define bob-err-sink (open-output-string))
(define bob-err-drain (thread (lambda () (copy-port bob-err bob-err-sink))))

(define (gift-fail msg)
  (eprintf "racket-goblins-gift FAILED: ~a\n" msg)
  (define berr (string-trim (get-output-string bob-err-sink)))
  (unless (string=? berr "")
    (eprintf "racket-goblins-gift: exporter stderr:\n~a\n" berr))
  (kill-children!)
  (exit 1))

(with-handlers ([(lambda (_) #t)
                 (lambda (e) (gift-fail (if (exn? e) (exn-message e) (format "~a" e))))])
  (await-greeter-ready bob-out "never saw the exporter's greeter readiness line")
  (printf "racket-goblins-gift: goblins-bob exporting greeter swiss=~a on ~a:~a\n"
          GREETER-SWISS HOST PORT)

  ;; pancake (the gifter) listens for the recipient on an ephemeral port and runs
  ;; its accept loop in a background thread, serving each accepted connection on
  ;; its own thread. One node identity (the server's node) serves both the
  ;; recipient connection and the exporter connection, so the give's signature
  ;; matches the deposit.
  (define gifter (listen HOST 0))
  (define gifter-port (server-port gifter))
  (define gifter-host (server-host gifter))
  (thread
   (lambda ()
     (let loop ()
       (define conn
         (with-handlers ([(lambda (_) #t) (lambda (_) #f)]) (accept gifter)))
       (when conn
         (thread (lambda () (with-handlers ([(lambda (_) #t) void]) (session-serve conn))))
         (loop)))))

  ;; Dial Bob and fetch his greeter. The fetched ref's home is this gifter↔Bob
  ;; connection, which is what lets pancake re-gift it across to the recipient.
  (define to-bob (connect (tcp-locator HOST PORT) #:host gifter-host))
  (define greeter (session-fetch to-bob GREETER-SWISS))
  (unless (far-ref? greeter) (gift-fail "could not fetch goblins-bob's greeter"))
  (printf "racket-goblins-gift: fetched goblins-bob's greeter\n")

  ;; Publish the introducer host-wide. Returning Bob's greeter (home = the Bob
  ;; connection) to the recipient's connection trips the transparent gifter,
  ;; which deposits with Bob and resolves the recipient with a signed give.
  (host-publish-giftable gifter-host INTRODUCER-SWISS
                            (methods [(get-greeter) greeter]))
  (printf "racket-goblins-gift: pancake publishing introducer swiss=~a on ~a:~a\n"
          INTRODUCER-SWISS HOST gifter-port)

  ;; Spawn Carol (the Goblins recipient): she dials pancake's introducer, asks
  ;; for the greeter, redeems pancake's give, and calls Bob directly.
  (define-values (carol carol-out carol-in carol-err)
    (subprocess #f #f #f RACKET RECIPIENT-SCRIPT
                (socket-addr-designator HOST gifter-port) INTRODUCER-SWISS
                (number->string (+ PORT 1))))
  (track-child! carol)
  (close-output-port carol-in)
  (define carol-err-sink (open-output-string))
  (define carol-err-drain (thread (lambda () (copy-port carol-err carol-err-sink))))

  (define reply (string-trim (port->string carol-out)))
  (subprocess-wait carol)
  (thread-wait carol-err-drain)
  (define carol-code (subprocess-status carol))
  (define carol-err-text (string-trim (get-output-string carol-err-sink)))
  (unless (string=? reply "") (printf "racket-goblins-gift: ~a\n" reply))
  (unless (zero? carol-code)
    (gift-fail (format "recipient exited non-zero (~a)~a" carol-code
                  (if (string=? carol-err-text "") "" (format "; stderr:\n~a" carol-err-text)))))
  (unless (and (string-prefix? reply "GIFT OK:") (string-contains? reply "goblins-carol"))
    (gift-fail (format "recipient did not confirm the greeter reply with its name: ~s" reply)))

  (printf "racket-goblins-gift OK: pancake minted a three-party handoff give that live Goblins redeemed, reaching the exporter directly\n")

  (session-close! to-bob)
  (server-close! gifter)
  (kill-children!)
  (exit 0))
