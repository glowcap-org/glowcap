#lang racket/base
;; Racket dogfood of the Zig libpancake C ABI, through the idiomatic `pancake.rkt`
;; module: drive OCapN with native Racket values and event structs — no FFI in
;; sight. This is the consumer `zig build bindings` runs.

(require "pancake.rkt"
         ffi/unsafe
         racket/tcp)

(define (fail msg) (eprintf "racket zig-smoke FAILED: ~a\n" msg) (exit 1))
(define (expect cond msg) (unless cond (fail msg)))

;; The linked library reports a real ABI version.
(let-values ([(major minor patch) (abi-version)])
  (expect (positive? (+ major minor patch)) "abi-version is nonzero"))

;; Construct a call with native args, then read it back as a typed event.
(define caller (make-peer))
(peer-register-import! caller 5)
(peer-send-deliver! caller (far 5) (list 42 #"hi") #:answer 9)
(peer-step! caller)
(define wire (peer-take-outbound caller))
(expect (and wire (regexp-match? #rx#"^<10'op:deliver" wire)) "constructed a real op:deliver")
(peer-release! caller)

(define callee (make-peer))
(peer-register-export! callee 7)
(peer-feed! callee #"<10'op:deliver<11'desc:export7+>[5:hello]11+f>")
(define ev (peer-poll callee))
(expect (deliver-event? ev) "got a deliver event")
(expect (and (near-ref? (deliver-event-target ev)) (= 7 (near-ref-id (deliver-event-target ev)))) "target near export 7")
(expect (= 11 (deliver-event-answer ev)) "answer is 11")
(expect (equal? (deliver-event-args ev) (list #"hello")) "one bytes arg 'hello'")
(peer-release! callee)

;; A context with a host allocator backs a peer; feed-owned transfers the frame
;; into the inbound queue and the deliver still surfaces. The custom allocator
;; counts blocks so we prove the library routed through it.
(define alloc-count (box 0))
(define ctx
  (make-context/allocator
   (lambda (size alignment)
     (set-box! alloc-count (add1 (unbox alloc-count)))
     (malloc 'raw (max size 1)))
   (lambda (ptr size alignment) (free ptr))))
(define owned-callee (make-peer/in ctx))
(peer-register-export! owned-callee 7)
(peer-feed-owned! owned-callee #"<10'op:deliver<11'desc:export7+>[5:hello]11+f>")
(peer-step! owned-callee)
(define owned-ev (peer-poll owned-callee))
(expect (deliver-event? owned-ev) "feed-owned: got a deliver event")
(expect (and (near-ref? (deliver-event-target owned-ev)) (= 7 (near-ref-id (deliver-event-target owned-ev))))
        "feed-owned: target near export 7")
(expect (= 11 (deliver-event-answer owned-ev)) "feed-owned: answer is 11")
(expect (equal? (deliver-event-args owned-ev) (list #"hello")) "feed-owned: one bytes arg 'hello'")
(expect (positive? (unbox alloc-count)) "host allocator was used by the context")
(peer-release! owned-callee)
(context-release! ctx)

;; An inbound abort surfaces as a typed event.
(define peer (make-peer))
(peer-feed! peer #"<8'op:abort3\"bye>")
(define abort (peer-poll peer))
(expect (and (other-event? abort) (= 7 (other-event-kind abort))) "abort surfaced as a typed event")
(expect (not (peer-poll peer)) "no further events")
(peer-release! peer)

(printf "racket zig-smoke OK: drove OCapN through the idiomatic pancake API\n")

;; ── Async: drive two peers over real Racket TCP ports ─────────────────────────
;; A server thread listens on an ephemeral port, accepts, hosts export 7, and
;; replies to the first deliver with a Fulfill. The main thread connects,
;; imports 7, calls far(7) with answer 9, and asserts the Resolve settling 9.
(define listener (tcp-listen 0 4 #t "127.0.0.1"))
(define-values (_lh server-port _rh _rp) (tcp-addresses listener #t))
(define result-ch (make-channel))

(define server
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) (lambda (e) (channel-put result-ch e))])
       (define-values (sin sout) (tcp-accept listener))
       (define speer (make-peer))
       (peer-register-export! speer 7)
       (define sconn (async-connection/ports speer sin sout))
       (define ev (async-next-event sconn))
       (expect (deliver-event? ev) "server: got a deliver event")
       (expect (and (near-ref? (deliver-event-target ev)) (= 7 (near-ref-id (deliver-event-target ev))))
               "server: target near export 7")
       (define answer (deliver-event-answer ev))
       (expect answer "server: deliver carried an answer")
       (async-send-resolve! sconn answer (fulfill #"pong"))
       (channel-put result-ch 'done)))))

(define client-conn (async-connect "127.0.0.1" server-port))
(peer-register-import! (async-connection-peer client-conn) 7)
(async-send-deliver! client-conn (far 7) (list #"ping") #:answer 9)
(define resolve-ev (async-next-event client-conn))
(expect (resolve-event? resolve-ev) "client: got a resolve event")
(expect (= 9 (resolve-event-answer resolve-ev)) "client: resolve settles answer 9")
(expect (and (fulfill? (resolve-event-resolution resolve-ev))
             (equal? #"pong" (fulfill-value (resolve-event-resolution resolve-ev))))
        "client: fulfilled with #\"pong\"")

;; Surface any server-side failure.
(define server-result (channel-get result-ch))
(when (exn? server-result) (raise server-result))
(expect (eq? 'done server-result) "server completed cleanly")
(tcp-close listener)

(printf "racket zig-smoke OK: drove async OCapN over Racket TCP ports\n")
