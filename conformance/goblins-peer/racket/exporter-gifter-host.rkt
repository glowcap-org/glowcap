#lang racket
;; exporter-gifter-host.rkt — Goblins Alice, the gifter in the handoff role
;; pancake had never played live: **pancake as the exporter**.
;;
;; The two shipped proofs cover the other two roles. `goblins-handoff` has
;; pancake redeem a give Goblins minted, and `goblins-gift` has pancake mint a
;; give Goblins redeems. Neither has a live Goblins pair deposit into and
;; withdraw from a *pancake* gift registry, so pancake answering `deposit-gift`
;; and `withdraw-gift` for somebody else's implementation rested on the
;; upstream suite and an in-tree scenario. This script is the missing half.
;;
;; The shape, and how it differs from `handoff-introducer-host.rkt`: there,
;; Alice enlivens a greeter hosted by a second Goblins vat (Bob) and gifts it,
;; so Goblins is both gifter and exporter. Here Alice enlivens a greeter hosted
;; by *pancake* and gifts that, so the exporter is pancake. A Goblins recipient
;; (`gift-recipient.rkt`) then enlivens Alice's introducer, asks for the
;; greeter, and receives a `desc:handoff-give` naming pancake — which it can
;; only use by dialing pancake directly and presenting a `desc:handoff-receive`.
;; If pancake's gift registry mis-answers either verb, the recipient's call
;; never lands.
;;
;; Usage:
;;   racket exporter-gifter-host.rkt <alice-port> <pancake-designator> <greeter-swiss>
;;
;; Stdout (line-buffered NDJSON):
;;   {"v":1,"event":"vat-ready","vat":"alice","listen":"127.0.0.1:<alice-port>"}
;;   {"v":1,"event":"cap-published","vat":"alice","name":"introducer","swiss":"<swiss>"}
;; then sleeps until killed.

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt")

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; A fixed swiss for the introducer so the recipient can address it, the same
;; constant `gift-recipient.rkt` dials.
(define INTRODUCER-SWISS
  (string->bytes/latin-1 "introducerSwissnum0123456789ABCD"))

(define (^introducer _bcom greeter-ref)
  (lambda args
    (case (and (pair? args) (car args))
      [(get-greeter) greeter-ref]
      [else (error '^introducer "unknown command: ~v" args)])))

(define argv (current-command-line-arguments))
(define alice-port
  (if (>= (vector-length argv) 1) (string->number (vector-ref argv 0)) 9011))
(define pancake-designator
  (if (>= (vector-length argv) 2) (vector-ref argv 1) "127.0.0.1:9012"))
(define greeter-swiss
  (if (>= (vector-length argv) 3) (vector-ref argv 2) "greeter"))

(define (emit-ndjson event-fields)
  (define (escape s) (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields]) (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ",")))

;; ── Alice: enliven pancake's greeter, host an introducer over it ─────────────
;; Same struct-constructor route `gift-recipient.rkt` uses: the net/url parser
;; rejects `host:port` in the subdomain field, so build the sturdyref directly.
(define alice-vat (make-vat))
(alice-vat
 'run
 (lambda ()
   (define netlayer (spawn ^tcp-netlayer "127.0.0.1" alice-port))
   (define mycapn (spawn-mycapn netlayer))
   (define nonce-registry ($ mycapn 'get-registry))

   (define greeter-sturdyref
     (ocapn-sturdyref
      (ocapn-node 'tcp pancake-designator #f)
      (string->bytes/latin-1 greeter-swiss)))

   ;; Enlivening opens an Alice -> pancake connection. The vow goes to the
   ;; introducer unresolved; Goblins pipelining lets the introducer hand it
   ;; out, and the gift is minted against pancake as the exporter when a
   ;; recipient asks for it.
   (define greeter-vow (<- mycapn 'enliven greeter-sturdyref))
   (define introducer (spawn ^introducer greeter-vow))
   ($ nonce-registry 'register introducer INTRODUCER-SWISS)

   (on (<- netlayer 'our-location)
       (lambda (_loc)
         (emit-ndjson `(("event" . "vat-ready") ("vat" . "alice")
                        ("listen" . ,(format "127.0.0.1:~a" alice-port))))
         (emit-ndjson `(("event" . "cap-published") ("vat" . "alice")
                        ("name" . "introducer")
                        ("swiss" . ,(bytes->string/latin-1 INTRODUCER-SWISS))))))))

(sync (make-semaphore))
