#lang racket
;; seven-caps-peer.rkt — long-running Goblins peer registering the
;; seven canonical OCapN test caps at the swiss-nums the conformance
;; suite expects.
;;
;; Adapted from upstream Spritely's misc/ocapn-test-suite.scm
;; (Apache 2.0). Swapped the onion netlayer for our local
;; tcp-netlayer.rkt so the suite's `tcp-testing-only` URL form can
;; reach this peer over loopback (Docker-host networking) without
;; requiring a Tor sidecar in CI.
;;
;; Usage:
;;   racket seven-caps-peer.rkt                # binds 127.0.0.1:22045
;;   racket seven-caps-peer.rkt 0.0.0.0 22045  # custom bind host/port
;;
;; URL the conformance suite dials (printed at startup):
;;   ocapn://<swiss-base64>.tcp-testing-only?host=127.0.0.1&port=22045
;;
;; Suite invocation (separate terminal):
;;   bash reference/tests/ocapn-conformance/run.sh test '<that-url>'
;;
;; The `JadQ0++R...` swiss-num below is the canonical Car Factory
;; builder swiss-num the suite expects; the URL printed at startup
;; uses it. The suite's other tests fetch the other swiss-nums
;; directly via op:bootstrap → op:fetch.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt")

;; Docker captures stdout/stderr without a tty; force line-buffering so
;; "ready" / URL banners show up in `docker logs` immediately rather
;; than being held in the block-buffer until exit.
(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

(define a-vat (make-vat))

(define (trigger-gc)
  (sleep 1)
  (collect-garbage))

;; ─────────────────────────────────────────────────────────────────
;; Seven canonical caps — copied verbatim from Spritely's reference
;; (misc/ocapn-test-suite.scm in spritely/racket-goblins). Behavior is
;; what the suite asserts against; do not modify without a matching
;; suite-side change.
;; ─────────────────────────────────────────────────────────────────

(define (^car _bcom color model)
  (lambda ()
    (format "Vroom! I am a ~a ~a car!" color model)))

(define (^car-factory _bcom)
  (lambda car-specs
    (define cars
      (for/list ([car-spec car-specs])
        (apply spawn ^car car-spec)))
    (apply values cars)))

(define (^car-factory-builder _bcom)
  (lambda ()
    (spawn ^car-factory)))

(define (^echo _bcom)
  (lambda args
    (syscaller-free-thread trigger-gc)
    args))

(define (^greeter _bcom)
  (lambda (refr)
    (syscaller-free-thread trigger-gc)
    (<- refr "Hello")))

(define (^promise-resolver _bcom)
  (lambda ()
    (define-values (vow resolver)
      (spawn-promise-values))
    (list vow resolver)))

(define (^sturdyref-enlivener _bcom mycapn)
  (lambda (sref)
    (<- mycapn 'enliven sref)))

;; ─────────────────────────────────────────────────────────────────
;; Server bootstrap: bind TCP, spawn caps, register at canonical
;; swiss-nums via the registry behind mycapn.
;; ─────────────────────────────────────────────────────────────────

(define argv (current-command-line-arguments))

(define listen-host
  (if (>= (vector-length argv) 1)
      (vector-ref argv 0)
      "127.0.0.1"))

(define listen-port
  (if (>= (vector-length argv) 2)
      (string->number (vector-ref argv 1))
      22045))

(define (start-server)
  (define tcp-netlayer (spawn ^tcp-netlayer listen-host listen-port))
  (define mycapn (spawn-mycapn tcp-netlayer))
  (define nonce-registry ($ mycapn 'get-registry))

  (define car-factory-builder (spawn ^car-factory-builder))
  (define car-factory-builder-swiss-num
    (string->bytes/latin-1 "JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ"))
  ($ nonce-registry 'register car-factory-builder car-factory-builder-swiss-num)

  (define echo (spawn ^echo))
  (define echo-swiss-num
    (string->bytes/latin-1 "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"))
  ($ nonce-registry 'register echo echo-swiss-num)

  (define greeter (spawn ^greeter))
  (define greeter-swiss-num
    (string->bytes/latin-1 "VMDDd1voKWarCe2GvgLbxbVFysNzRPzx"))
  ($ nonce-registry 'register greeter greeter-swiss-num)

  (define promise-resolver (spawn ^promise-resolver))
  (define promise-resolver-swiss-num
    (string->bytes/latin-1 "IokCxYmMj04nos2JN1TDoY1bT8dXh6Lr"))
  ($ nonce-registry 'register promise-resolver promise-resolver-swiss-num)

  (define sturdyref-enlivener (spawn ^sturdyref-enlivener mycapn))
  (define sturdyref-enlivener-swiss-num
    (string->bytes/latin-1 "gi02I1qghIwPiKGKleCQAOhpy3ZtYRpB"))
  ($ nonce-registry 'register sturdyref-enlivener sturdyref-enlivener-swiss-num)

  (values tcp-netlayer car-factory-builder car-factory-builder-swiss-num))

(a-vat
 'run
 (lambda ()
   (define-values (tcp-netlayer car-factory-builder car-factory-builder-swiss-num)
     (start-server))
   (on (<- tcp-netlayer 'our-location)
       (lambda (location)
         (printf "~n=== seven-caps-peer ready ===~n")
         (printf "Bound: ~a~n" (ocapn-node->string location))
         (printf "Conformance suite URL (Car Factory builder):~n")
         (printf "  ocapn://~a?host=~a&port=~a~n"
                 ;; The suite parses the path-component swiss as
                 ;; raw bytes, but the URL form needs the swiss as
                 ;; URL-safe characters. The canonical swiss-nums
                 ;; the suite uses ARE URL-safe ASCII, so we can
                 ;; embed them directly.
                 (let ([sub-domain
                        (bytes->string/latin-1
                         car-factory-builder-swiss-num)])
                   (string-append sub-domain ".tcp-testing-only"))
                 listen-host
                 listen-port)
         (printf "~n(other swiss-nums also registered: Echo GC, Greeter, Promise Resolver, Sturdyref enlivener)~n")
         (printf "Press Ctrl-C to stop.~n~n")))))

(sync (make-semaphore))
