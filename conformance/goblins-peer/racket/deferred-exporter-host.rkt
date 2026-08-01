#lang racket
;; deferred-exporter-host.rkt — Goblins Bob, the exporter whose capability does
;; not exist yet. He is the far end of the relayed-give proof
;; (`zig build goblins-relayed-give`), where pancake introduces a third party to
;; a promise Bob has not settled.
;;
;; Bob hosts a promise, not a greeter. `spawn-promise-values` gives him a
;; promise and its resolver; the greeter is spawned later, when the driver asks
;; for it. What he publishes is a rendezvous: pancake fetches it and calls
;; `hold-with`, handing over a capability of its own, and Bob replies by sending
;; the unresolved promise *to* that capability as a delivered argument. That
;; direction matters. An answer carrying a local promise chains through Goblins'
;; own promise machinery and stays pending on the wire, so pancake would be
;; handed a pending answer rather than a promise it can name. An argument
;; marshals as `desc:import-promise`, which is what pancake needs in order to
;; introduce it to somebody else.
;;
;; Bob settles the promise on the first line of stdin, so the driver decides
;; when. Once it settles, Bob's listener fire carries the greeter to pancake,
;; pancake signs a give for the third party, and Bob then answers that party's
;; own `withdraw-gift` directly.
;;
;; Usage:
;;   racket deferred-exporter-host.rkt <bind-host> <bind-port>
;;   then write one line to stdin to settle the promise.
;;
;; Stdout (line-buffered NDJSON):
;;   {"v":1,"event":"vat-ready","vat":"goblins-bob","listen":"127.0.0.1:22150"}
;;   {"v":1,"event":"cap-published","vat":"goblins-bob","name":"rendezvous","swiss":"…"}
;;   {"v":1,"event":"promise-settled","vat":"goblins-bob","name":"greeter"}

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt")

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; The rendezvous swiss pancake fetches by. 32 ASCII bytes, like every other
;; fixed swiss in this directory.
(define RENDEZVOUS-SWISS
  (string->bytes/latin-1 "pancakeDeferredRendezvousSwiss01"))

;; The capability the promise settles to. It answers with the caller's name
;; embedded, so a recipient that reaches it through a relayed give proves the
;; handoff carried real data and not merely a live reference.
(define (^greeter _bcom)
  (lambda (name)
    (format "hello ~a, from goblins-bob" name)))

;; Bob's published object. `hold-with` takes the capability pancake exports and
;; sends the unresolved promise to it, which is the one shape that reaches
;; pancake as `desc:import-promise`.
(define (^rendezvous _bcom greeter-vow)
  (lambda args
    (case (and (pair? args) (car args))
      [(hold-with)
       (<-np (cadr args) 'hold greeter-vow)
       'held]
      [else (error '^rendezvous "unknown command: ~v" args)])))

(define argv (current-command-line-arguments))

(define listen-host
  (if (>= (vector-length argv) 1) (vector-ref argv 0) "127.0.0.1"))

(define listen-port
  (if (>= (vector-length argv) 2)
      (string->number (vector-ref argv 1))
      22150))

(define (emit-ndjson event-fields)
  (define (escape s) (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields])
      (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ",")))

(define a-vat (make-vat))

;; The resolver escapes the vat's own turn so the stdin reader below can settle
;; the promise later. It is only ever *used* inside another `'run` on this same
;; vat, which is where a Goblins reference is allowed to be called. The reader
;; empties the box before fulfilling, so the promise settles at most once.
(define resolver-box (box #f))

(a-vat
 'run
 (lambda ()
   (define tcp-netlayer (spawn ^tcp-netlayer listen-host listen-port))
   (define mycapn (spawn-mycapn tcp-netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   (define-values (greeter-vow greeter-resolver) (spawn-promise-values))
   (set-box! resolver-box greeter-resolver)
   (define rendezvous (spawn ^rendezvous greeter-vow))
   ($ nonce-registry 'register rendezvous RENDEZVOUS-SWISS)
   (on (<- tcp-netlayer 'our-location)
       (lambda (_location)
         (emit-ndjson
          `(("event" . "vat-ready")
            ("vat" . "goblins-bob")
            ("listen" . ,(format "~a:~a" listen-host listen-port))))
         (emit-ndjson
          `(("event" . "cap-published")
            ("vat" . "goblins-bob")
            ("name" . "rendezvous")
            ("swiss" . ,(bytes->string/latin-1 RENDEZVOUS-SWISS))))))))

;; Settle on demand, once. A promise fulfilled twice raises inside the vat, so
;; the first line of stdin takes the resolver and every later line finds the box
;; empty. End-of-input leaves Bob serving, because the recipient still has to
;; withdraw the gift and call what it withdrew.
(let loop ()
  (define line (read-line))
  (cond
    [(eof-object? line) (sync (make-semaphore))]
    [else
     (define resolver (unbox resolver-box))
     (when resolver
       (set-box! resolver-box #f)
       (a-vat 'run (lambda () ($ resolver 'fulfill (spawn ^greeter))))
       (emit-ndjson
        `(("event" . "promise-settled")
          ("vat" . "goblins-bob")
          ("name" . "greeter"))))
     (loop)]))
