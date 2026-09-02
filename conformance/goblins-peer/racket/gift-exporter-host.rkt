#lang racket
;; gift-exporter-host.rkt — Goblins Bob, the exporter in the glowcap-as-gifter
;; three-party handoff proof. Hosts a `^greeter` cap behind a fixed swiss-num,
;; emits an NDJSON readiness line (listen address + greeter swiss), then sleeps.
;;
;; In this scenario glowcap is the *gifter*: it fetches this greeter, deposits it
;; back here as a gift over its own connection, and mints a `desc:handoff-give`.
;; A Goblins recipient then withdraws the gift directly from this vat. So this
;; host proves two cross-implementation directions at once — Goblins accepting
;; glowcap's `deposit-gift`, and Goblins serving the recipient's `withdraw-gift`.
;;
;; Usage:
;;   racket gift-exporter-host.rkt <bind-host> <bind-port> [hint-name hint-hex]
;;
;; With the optional pair, this vat's advertised location carries a hints
;; mapping `{hint-name: <bytes of hint-hex>}` in its hello. The gifter then
;; embeds that hinted location verbatim in its `desc:handoff-give`. This checks
;; Goblins' mapping-shaped hint round trip with opaque route metadata.
;;
;; Stdout (line-buffered NDJSON):
;;   {"v":1,"event":"vat-ready","vat":"goblins-bob","listen":"127.0.0.1:22120"}
;;   {"v":1,"event":"cap-published","vat":"goblins-bob","name":"greeter","swiss":"…"}

(require goblins
         goblins/vat
         goblins/ocapn/captp
         goblins/ocapn/structs-urls
         "tcp-netlayer.rkt")

(file-stream-buffer-mode (current-output-port) 'line)
(file-stream-buffer-mode (current-error-port) 'line)

;; Fixed swiss-num glowcap fetches by (it hardcodes the same ASCII constant, the
;; way the interop clients fix the echo swiss). 32 ASCII bytes, like the echo cap.
(define GREETER-SWISS
  (string->bytes/latin-1 "glowcapGiftGreeterSwissnum000001"))
(define VENDOR-SWISS
  (string->bytes/latin-1 "glowcapGiftVendorSwissnum0000001"))

;; Greeter behavior, replies with the caller's name embedded, so the recipient
;; proves the handoff carried real data end to end, not just a live reference.
(define (^greeter _bcom)
  (lambda (name)
    (format "hello ~a, from goblins-bob" name)))

;; Return the greeter from an ordinary call. The binding gift matrix fetches
;; this vendor, not the greeter itself, so the capability it re-gifts proves
;; reply lifting composes with handoff.
(define (^vendor _bcom greeter)
  (lambda () greeter))

(define argv (current-command-line-arguments))

(define listen-host
  (if (>= (vector-length argv) 1) (vector-ref argv 0) "127.0.0.1"))

(define listen-port
  (if (>= (vector-length argv) 2)
      (string->number (vector-ref argv 1))
      22120))

(define (hex->bytes s)
  (define n (quotient (string-length s) 2))
  (define out (make-bytes n))
  (for ([i (in-range n)])
    (bytes-set! out i (string->number (substring s (* 2 i) (+ 2 (* 2 i))) 16)))
  out)

(define location-hints
  (and (>= (vector-length argv) 4)
       (hash (vector-ref argv 2) (hex->bytes (vector-ref argv 3)))))

(define (emit-ndjson event-fields)
  (define (escape s) (regexp-replace* #px"[\\\\\"]" s "\\\\\\0"))
  (define pairs
    (for/list ([f event-fields])
      (format "\"~a\":\"~a\"" (car f) (escape (cdr f)))))
  (printf "{\"v\":1,~a}~n" (string-join pairs ",")))

(define a-vat (make-vat))

(a-vat
 'run
 (lambda ()
   (define tcp-netlayer
     (spawn ^tcp-netlayer listen-host listen-port #:location-hints location-hints))
   (define mycapn (spawn-mycapn tcp-netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   (define greeter (spawn ^greeter))
   (define vendor (spawn ^vendor greeter))
   ($ nonce-registry 'register greeter GREETER-SWISS)
   ($ nonce-registry 'register vendor VENDOR-SWISS)
   (on (<- tcp-netlayer 'our-location)
       (lambda (_location)
         (emit-ndjson
          `(("event" . "vat-ready")
            ("vat" . "goblins-bob")
            ("listen" . ,(format "~a:~a" listen-host listen-port))))
         (emit-ndjson
          `(("event" . "cap-published")
            ("vat" . "goblins-bob")
            ("name" . "greeter")
            ("swiss" . ,(bytes->string/latin-1 GREETER-SWISS))))))))

(sync (make-semaphore))
