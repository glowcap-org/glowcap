#lang racket
;; gift-exporter-host.rkt — Goblins Bob, the exporter in the pancake-as-gifter
;; three-party handoff proof. Hosts a `^greeter` cap behind a fixed swiss-num,
;; emits an NDJSON readiness line (listen address + greeter swiss), then sleeps.
;;
;; In this scenario pancake is the *gifter*: it fetches this greeter, deposits it
;; back here as a gift over its own connection, and mints a `desc:handoff-give`.
;; A Goblins recipient then withdraws the gift directly from this vat. So this
;; host proves two cross-implementation directions at once — Goblins accepting
;; pancake's `deposit-gift`, and Goblins serving the recipient's `withdraw-gift`.
;;
;; Usage:
;;   racket gift-exporter-host.rkt <bind-host> <bind-port>
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

;; Fixed swiss-num pancake fetches by (it hardcodes the same ASCII constant, the
;; way the interop clients fix the echo swiss). 32 ASCII bytes, like the echo cap.
(define GREETER-SWISS
  (string->bytes/latin-1 "pancakeGiftGreeterSwissnum000001"))

;; Greeter behavior, replies with the caller's name embedded, so the recipient
;; proves the handoff carried real data end to end, not just a live reference.
(define (^greeter _bcom)
  (lambda (name)
    (format "hello ~a, from goblins-bob" name)))

(define argv (current-command-line-arguments))

(define listen-host
  (if (>= (vector-length argv) 1) (vector-ref argv 0) "127.0.0.1"))

(define listen-port
  (if (>= (vector-length argv) 2)
      (string->number (vector-ref argv 1))
      22120))

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
   (define tcp-netlayer (spawn ^tcp-netlayer listen-host listen-port))
   (define mycapn (spawn-mycapn tcp-netlayer))
   (define nonce-registry ($ mycapn 'get-registry))
   (define greeter (spawn ^greeter))
   ($ nonce-registry 'register greeter GREETER-SWISS)
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
